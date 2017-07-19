stream = require 'readable-stream'
throttle = require 'lodash.throttle'

module.exports = (requestModule, requestOpts, opts) ->
	return new ResumableRequest(requestModule, requestOpts, opts)

module.exports.defaults = (defaults = {}) ->
	(requestModule, requestOpts, opts) ->
		opts = Object.assign {}, defaults, opts
		return new ResumableRequest(requestModule, requestOpts, opts)

cloneResponse = (response) ->
	# creates an `http.IncomingMessage`-like stream, that can also be piped to.
	s = new stream.PassThrough()
	[ 'headers', 'httpVersion', 'method', 'rawHeaders', 'statusCode', 'statusMessage' ].forEach (prop) ->
		s[prop] = response[prop]
	return s

wrapLegacyStream = (s) ->
	new stream.Readable().wrap(s)

class ResumableRequest extends stream.Readable
	constructor: (@requestModule, @requestOpts, opts = {}) ->
		super()

		@error = null
		@request = null
		@response = null

		@bytesRead = 0
		@bytesTotal = null
		@retries = 0
		@maxRetries = opts.maxRetries ? 10

		@_retry = throttle(@_retry.bind(this), opts.retryInterval ? 1000)
		@_reportProgress = throttle(@_reportProgress.bind(this), opts.progressInterval ? 1000)

		@on 'pipe', ->
			# request can be written to when uploading a resource to a URL.
			# We do not support that -- resumable request can only be used
			# to *download* a resource, i.e. only the response is resumable.
			# piping will fail as soon as the stream gets going because we don't
			# implement Writable but it's better to fail early.
			throw new Error('ResumableRequest is not writable.')

		@_request()

	abort: ->
		@emit('abort')
		@_end()

	push: (data, encoding) ->
		@retries = 0 # we got some data, reset number of retries
		@bytesRead += data.length if data?
		@_reportProgress()
		return super(data, encoding)

	_end: ->
		return if @ended
		@ended = true
		doEnd = =>
			@request.abort()
			@_retry.cancel()
			@_reportProgress()
			@_reportProgress.flush()
			@_reportProgress.cancel()
			@emit('end')
			if not @error?
				@emit('complete')
		if @response?
			@response.end(doEnd)
		else
			doEnd()

	_read: -> # noop -- we're manually pushing buffers into self

	progress: ->
		retries: @retries
		maxRetries: @maxRetries
		percentage: Math.round(100 * @bytesRead / @bytesTotal) or 0
		size: { transferred: @bytesRead, total: @bytesTotal }

	_reportProgress: (progress = {}) =>
		@emit('progress', Object.assign(@progress(), progress))

	# Sends the requests and sets up listeners in order
	# to be able to resume.
	# Returns a stream object similar to the result of `request`.
	# 'response' and 'request' events on the stream are generated
	# based on the first request, in order to emit them only once.
	_request: ->
		if @response?
			# the first response is emitted to listeners, so only specify the
			# Range header on subsequent requests, to avoid causing a 206 response
			# status code, which may be unexpected.
			@requestOpts.headers ?= {}
			@requestOpts.headers.range = "bytes=#{@bytesRead}-"

		initial = @request is null
		aborted = false
		errored = false

		@request = @requestModule(@requestOpts)
		.once 'request', (reqObj) =>
			if initial
				@emit('request', reqObj)
		.once 'response', (response) =>
			@_follow(response)
			if response.statusCode >= 400
				@error = new Error("Request failed with status code #{response.statusCode}")
				@_retry() # will abort the request
		.on 'error', (err) =>
			errored = true
			@emit('socketError', err)
			if aborted
				@_retry()
		.once 'abort', ->
			aborted = true
		.once 'complete', =>
			if errored or (@bytesTotal? and @bytesRead < @bytesTotal)
				@_retry()
			else
				@_end() # received complete response

	_follow: (response) ->
		if not @response?
			@bytesTotal ?= parseInt(response.headers['content-length'])
			@_reportProgress()
			@_reportProgress.flush()
			@response = cloneResponse(response).on('data', @push.bind(this))
			@emit('response', @response)

		# wrapping the stream in a v3 Readable stream streamlines the emission
		# of some events and avoids some weird edge-cases
		wrapLegacyStream(response).pipe(@response, end: false)

	# Decide whether to resume downloading based on number
	# of bytes downloaded and maximum retries.
	_retry: ->
		try
			if @error?
				throw @error # we have already emitted an unrecoverable error
			if @response? and not @bytesTotal
				throw new Error('Cannot resume without Content-Length response header')
			if @response? and @response.headers['accept-ranges']?.toLowerCase() != 'bytes'
				throw new Error('Server does not support Byte Serving')
			if @bytesTotal and @bytesRead > @bytesTotal
				throw new Error('Received more bytes than expected!')
			if @retries >= @maxRetries
				throw new Error('Maximum retries exceeded')
		catch err
			@error = err
			@emit('error', err)
			@abort()
			return

		@retries += 1
		@emit('retry', @progress())
		@_request()
