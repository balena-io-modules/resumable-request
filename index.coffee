stream = require 'readable-stream'
throttle = require 'lodash.throttle'

# use the same module as request.js, to preserve behaviour.
# Object.assign() doesn't fit, because it copies `undefined`
# props as well, whereas we'd rather not.
extend = require 'extend'

module.exports = (requestModule, requestOpts, opts) ->
	return new ResumableRequest(requestModule, requestOpts, opts)

module.exports.defaults = (defaults = {}) ->
	(requestModule, requestOpts, opts) ->
		opts = extend {}, defaults, opts
		return new ResumableRequest(requestModule, requestOpts, opts)

cloneResponse = (response) ->
	# creates an `http.IncomingMessage`-like stream, that can also be piped to.
	s = new stream.PassThrough()
	[ 'headers', 'httpVersion', 'method', 'rawHeaders', 'statusCode', 'statusMessage' ].forEach (prop) ->
		s[prop] = response[prop]
	return s

class ResumableRequest extends stream.Readable
	constructor: (@requestModule, @requestOpts, opts = {}) ->
		super()

		@error = null
		@request = null
		@response = null

		@destinations = []

		@bytesRead = 0
		@bytesTotal = null
		@retries = 0
		@maxRetries = opts.maxRetries ? 10

		retryNow = @_retry.bind(this)
		@_retry = throttle(retryNow, opts.retryInterval ? 1000, leading: false)
		@_reportProgress = throttle(@_reportProgress.bind(this), opts.progressInterval ? 1000, leading: false)

		@on 'pipe', =>
			# request can be written to when uploading a resource to a URL.
			# We do not support that -- resumable request can only be used
			# to *download* a resource, i.e. only the response is resumable.
			# piping will fail with a not-so-obvious error as soon as the stream
			# gets going because we don't implement Writable, so detect this
			# and emit a more appropriate error.
			@error = new Error('ResumableRequest is not writable')
			# have to abort asynchronously to allow client code to register 'error' handlers
			process.nextTick(retryNow)

		@_request()

	abort: ->
		@emit('abort')
		@destroy(@error)

	push: (data, encoding) =>
		@retries = 0 # we got some data, reset number of retries
		@bytesRead += data.length if data?
		@_reportProgress()
		@emit('data', data)
		return @response.write(data, encoding)

	pipe: (dest, opts) ->
		if @response?
			return @response.pipe(dest, opts)
		@destinations.push([ dest, opts ])
		return dest

	_destroy: (err, cb) ->
		return cb(err) if @ended
		@ended = true
		# make sure to cleanly abort or detroy the underlying
		# request as appropriate immediately.
		if err
			@request.abort()
		else
			@request.destroy()
		@response?.end()
		@_retry.cancel()
		@_reportProgress()
		@_reportProgress.flush()
		@_reportProgress.cancel()
		cb(err)
		# `cb(err)` will emit the error on next tick, so schedule emittance
		# of 'end' on next tick as well to preserve event order.
		process.nextTick =>
			@emit('complete') if not err
			@emit('end')

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
		failed = false

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
			failed = true
			@emit('socketError', err)
			@_retry()
		.once 'complete', =>
			return if failed # we've already triggered a retry
			if @bytesTotal? and @bytesRead < @bytesTotal
				@_retry()
			else
				@destroy() # received complete response

	_follow: (response) ->
		if not @response?
			# Create a response "proxy" for the first response by wrapping it in a
			# custom PassThrough stream, copying interesting attributes such as
			# statusCode, headers, etc. This is needed because we only emit one
			# 'response' event where client code can attach listeners on.
			@bytesTotal ?= parseInt(response.headers['content-length'])
			@_reportProgress()
			@_reportProgress.flush()
			@response = cloneResponse(response)
			@destinations.forEach ([ dest, opts ]) =>
				@response.pipe(dest, opts)
			@destinations = []
			@emit('response', @response)

		onData = @push
		onEnd = ->
			response.removeListener('data', onData)
			response.removeListener('error', onEnd)
			response.removeListener('end', onEnd)
		response
			.on('data', onData)
			.once('error', onEnd)
			.once('end', onEnd)

	# Decide whether to resume downloading based on number
	# of bytes downloaded and maximum retries.
	_retry: ->
		return if @ended

		if @error?
			# we already have an unrecoverable error
		else if @response? and not @bytesTotal
			@error = new Error('Cannot resume without Content-Length response header')
		else if @response? and @response.headers['accept-ranges']?.toLowerCase() != 'bytes'
			@error = new Error('Server does not support Byte Serving')
		else if @bytesTotal and @bytesRead > @bytesTotal
			@error = new Error('Received more bytes than expected!')
		else if @retries >= @maxRetries
			@error = new Error('Maximum retries exceeded')
		else
			@retries += 1
			@emit('retry', @progress())
			@_request()
			return

		@abort()
