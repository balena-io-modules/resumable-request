EventEmitter = require 'events'
request = require 'simple-get'
stream = require 'readable-stream'
throttle = require 'lodash/throttle'

# Object.assign() doesn't fit, because it copies `undefined`
# props as well, whereas we'd rather not.
extend = require 'extend'

module.exports = (opts) ->
	return new ResumableRequest(opts)

module.exports.defaults = (defaults = {}) ->
	(opts) ->
		opts = extend {}, defaults, opts
		return new ResumableRequest(opts)

class _ResponseProxy extends stream.Readable
	constructor: (response, @timeout, @onProgress) ->
		super()
		@stream = response
		[ 'headers', 'httpVersion', 'method', 'rawHeaders', 'statusCode', 'statusMessage' ].forEach (prop) =>
			this[prop] = response[prop]
		@_ended = false

	follow: (response) ->
		if @stream?
			@stream.resume()
			@stream.removeListener('readable', @_read)
		@stream = response
		@stream.once('readable', @_read)

	_read: =>
		return if @_ended

		chunk = null
		chunksRead = 0

		# Read chunks from the source & push them out
		while (chunk = @stream.read())
			chunksRead++

			@onProgress(chunk)

			# Avoid pushing out more chunks than the destination can handle
			if @push(chunk) is false
				break

		# If no chunks were read, wait until the source becomes readable again
		if chunksRead is 0
			@stream.once('readable', @_read)

	_destroy: ->
		@_ended = true
		@push(null)
		if @stream?
			@stream.resume()
			@stream.removeListener('readable', @_read)

class ResumableRequest extends EventEmitter
	constructor: (opts) ->
		super()

		if not opts.url?
			throw new Error('You must specify a URL')
		if opts.method? and opts.method.toLowerCase() isnt 'get'
			throw new Error('Only GET requests are currently supported')

		defaultOpts = {
			maxRetries: 10
			retryInterval: 1000
			progressInterval: 1000
		}

		opts = extend(defaultOpts, opts)
		{ @maxRetries, @timeout, retryInterval, progressInterval } = opts
		delete opts.maxRetries
		delete opts.retryInterval
		delete opts.progressInterval
		delete opts.timeout

		@error = null
		@request = null
		@response = null
		@requestOpts = opts
		@requestOpts.headers ?= {}

		@bytesRead = 0
		@bytesTotal = null
		@retries = 0

		retryNow = @_retry
		@_retry = throttle(retryNow, retryInterval, leading: false)
		@_reportProgress = throttle(@_reportProgress, progressInterval, leading: false)

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

		process.nextTick(@_request)

	progress: ->
		retries: @retries
		maxRetries: @maxRetries
		percentage: Math.round(100 * @bytesRead / @bytesTotal) or 0
		size: { transferred: @bytesRead, total: @bytesTotal }

	_reportProgress: (progress = {}) =>
		@emit('progress', Object.assign(@progress(), progress))

	_request: =>
		if @response?
			# the first response is emitted to listeners, so only specify the
			# Range header on subsequent requests, to avoid causing a 206 response
			# status code, which may be unexpected.
			@requestOpts.headers ?= {}
			@requestOpts.headers.range = "bytes=#{@bytesRead}-"

		initial = @request is null

		reqFinished = false
		resFinished = false
		doRetry = =>
			if reqFinished and resFinished
				@_retry()

		@request = request @requestOpts, (err, response) =>
			if err?
				resFinished = true
				doRetry()
				return

			@_follow(response)

			response.once 'end', ->
				resFinished = true
				doRetry()

			if response.statusCode >= 400
				@error = new Error("Request failed with status code #{response.statusCode}")
				@request.abort()
		.once 'close', ->
			reqFinished = true
			doRetry()

		if @timeout
			@request.setTimeout(@timeout)

		@emit('request', @request) if initial

	_follow: (response) ->
		if not @response?
			# Create a response "proxy" for the first response by wrapping it in a
			# custom PassThrough stream, copying interesting attributes such as
			# statusCode, headers, etc. This is needed because we only emit one
			# 'response' event where client code can attach listeners on.
			@bytesTotal ?= parseInt(response.headers['content-length'])
			@_reportProgress()
			@_reportProgress.flush()
			@response = new _ResponseProxy response, @timeout, (data) =>
				@retries = 0
				@bytesRead += data.length
				@_reportProgress()
			@emit('response', @response)
		else
			@response.follow(response)

	# Decide whether to resume downloading based on number
	# of bytes downloaded and maximum retries.
	_retry: =>
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
		else if @bytesTotal? and @bytesRead is @bytesTotal
			@_end()
			return
		else
			@retries += 1
			@emit('retry', @progress())
			@_request()
			return

		@_abort(@error)

	abort: ->
		@request?.abort()

	_abort: (err) ->
		return if @ended
		@ended = true

		@response?.resume()
		@response?.destroy()

		if err?
			@emit('error', err)
		@emit('aborted')
		@emit('end')

	_end: ->
		return if @ended
		@ended = true
		@response.destroy()
		@emit('end')
