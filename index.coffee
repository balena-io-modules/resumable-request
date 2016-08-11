through = require 'through'

module.exports = (requestModule, requestOpts, opts) ->
	res = new Resumable(requestModule, requestOpts, opts)
	return res.resume()

class Resumable
	constructor: (requestModule, requestOpts, opts) ->
		@stream = through (data) =>
			@bytesRead += data.length
			@stream.emit('data', data)
		@bytesRead = 0
		@retries = 0
		@maxRetries = opts?.maxRetries ? 10
		@contentLength = null
		@requestOpts = requestOpts
		@requestModule = requestModule
		@error = null

	# Sends the requests and sets up listeners in order
	# to be able to resume.
	# Returns a stream object similar to the result of `request`.
	# 'response' and 'request' events on the stream are generated
	# based on the first request, in order to emit them only once.
	resume: ->
		@requestOpts.headers ?= {}
		@requestOpts.headers.range = "bytes=#{@bytesRead}-"
		@requestModule(@requestOpts)
		.on 'request', (reqObj) =>
			if @retries is 0
				@stream.emit('request', reqObj)
		.on 'response', (response) =>
			if response.statusCode >= 400
				@error = new Error("Request failed with status code #{response.statusCode}")
				@stream.emit('error', @error)
			else if @retries is 0
				@stream.emit('response', response)
				@contentLength = parseInt(response.headers['content-length'])
		.on 'error', (err) =>
			@stream.emit('socketError', err)
			@retryOrEnd()
		.on('end', => @retryOrEnd())
		.pipe(@stream, end: false)

	# Decide whether to resume downloading based on number
	# of bytes downloaded and maximum retries.
	retryOrEnd: ->
		if @error?
			return # we have emitted unrecoverable error (eg bad status code)
		else if not @contentLength?
			@stream.error('error', new Error('Cannot resume without Content-length response header'))
		else if @bytesRead == @contentLength
			@stream.end()
		else if @bytesRead > @contentLength
			@stream.emit('error', new Error('resumable received more bytes than expected'))
		else if @retries >= @maxRetries
			@stream.emit('error', new Error('maximum retries exceeded.'))
		else
			@retries += 1
			@resume()
