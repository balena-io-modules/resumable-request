through = require 'through'

module.exports = (requestModule, requestOpts, opts) ->
	throughStream = through (data) ->
		req.bytesRead += data.length
		@emit('data', data)
	req =
		stream: throughStream
		bytesRead: 0
		retries: 0
		maxRetries: opts?.maxRetries ? 10
		contentLength: null
		requestOpts: requestOpts
		requestModule: requestModule
		error: null
	resume(req)

# Sends the actual request and sets up listeners in order
# to be able to resume.
resume = (req) ->
	req.requestOpts.headers ?= {}
	req.requestOpts.headers.range = "bytes=#{req.bytesRead}-"
	req.requestModule(req.requestOpts)
	.on 'request', (reqObj) ->
		if req.retries is 0
			req.stream.emit('request', reqObj)
	.on 'response', (response) ->
		if response.statusCode >= 400
			req.error = new Error("Request failed with status code #{response.statusCode}")
			req.stream.emit('error', req.error)
		else if req.retries is 0
			req.stream.emit('response', response)
			req.contentLength = parseInt(response.headers['content-length'])
	.on 'error', (err) ->
		req.stream.emit('socketError', err)
		retryOrEnd(req)
	.on('end', retryOrEnd.bind(null, req))
	.pipe(req.stream, end: false)

# Decide whether to resume downloading based on number
# of bytes downloaded and maximum retries.
retryOrEnd = (req) ->
	if req.error?
		return # we have already emitted error (eg bad status code)
	else if req.bytesRead == req.contentLength
		req.stream.end()
	else if not req.contentLength?
		req.stream.error('error', new Error('Cannot resume without Content-length response header'))
	else if req.bytesRead > req.contentLength
		req.stream.emit('error', new Error('resumable received more bytes than expected'))
	else if req.retries >= req.maxRetries
		req.stream.emit('error', new Error('maximum retries exceeded.'))
	else
		req.retries += 1
		resume(req)
