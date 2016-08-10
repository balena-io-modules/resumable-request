through = require 'through'
request = require 'request'

module.exports = ({ url, maxRetries = 10 }) ->
	if not url?
		throw new Error('resumable requires url parameter')
	throughStream = through (data) ->
		req.bytesRead += data.length
		@emit('data', data)
	req =
		stream: throughStream
		bytesRead: 0
		retries: 0
		maxRetries: maxRetries
		contentLength: null
		requestOpts:
			url: url
	init(req)
	return req.stream

# Send a HEAD request to get total Content-length
# The "response" and "request" events are emitted on the resumable stream,
# to mimic what request would do if there was only one (non-resumable) request.
init = (req) ->
	request.head req.requestOpts.url , (err, response) ->
		if err?
			req.stream.emit('error', err)
			return
		{ statusCode, headers } = response
		req.stream.emit('response', response)
		if response.statusCode >= 400
			req.stream.emit('error', new Error("HEAD request failed with status code #{statusCode}"))
			return
		if not headers['content-length']?
			req.stream.emit('error', new Error('Missing "Content-length" header on resumable request'))
			return
		req.contentLength = parseInt(headers['content-length'])
		resume(req)
	.on 'request', (requestObj) ->
		req.stream.emit('request', requestObj)

# Sends the actual request and sets up listeners in order
# to be able to resume.
resume = (req) ->
	req.requestOpts.headers ?= {}
	req.requestOpts.headers.range = "bytes=#{req.bytesRead}-"
	request(req.requestOpts)
	.on 'error', (err) ->
		req.stream.emit('socketError', err)
		retryOrEnd(req)
	.on('end', retryOrEnd.bind(null, req))
	.pipe(req.stream, end: false)

# Decide whether to resume downloading based on number
# of bytes downloaded and maximum retries.
retryOrEnd = (req) ->
	if req.bytesRead == req.contentLength
		req.stream.end()
	else if req.bytesRead > req.contentLength
		req.stream.emit('error', new Error('resumable received more bytes than expected'))
	else if req.retries >= req.maxRetries
		req.stream.emit('error', new Error('maximum retries exceeded.'))
	else
		req.retries += 1
		resume(req)
