http = require 'http'
fs = require 'fs'
Range = require('http-range').Range
{ expect } = require 'chai'
url = require 'url'
stream = require 'readable-stream'

# we're emulating a flaky connection by simply not sending data from the test
# server down the socket. no need to wait for ages, so specify tiny timeouts.
request = require('request').defaults(timeout: 100)
resumable = require('../').defaults(retryInterval: 100, maxRetries: 2)

TEST_PORT = process.env.TEST_PORT ? 5000
TEST_FILE = './test/test.html'
TEST_FILE_LENGTH = 128086
TEST_BROKEN_RESPONSE_SIZE = 40000

# returns only TEST_BROKEN_RESPONSE_SIZE bytes per request
# to test resumable downloads
brokenServer = http.createServer (req, res) ->
	opts = {}
	# supports only one range definition (no commas)
	if req.headers.range?
		# supports only one range of format bytes=low-
		[ range ] = Range.prototype.parse(req.headers.range).ranges
		opts.start = range.low ? 0
		opts.end = range.low + TEST_BROKEN_RESPONSE_SIZE - 1
	else
		opts.start = 0
		opts.end = TEST_BROKEN_RESPONSE_SIZE - 1
	qs = url.parse(req.url, true).query
	if qs.hang?
		return # hang forever; will cause socket timeout
	if not qs.noContentLength?
		res.setHeader('Content-length', TEST_FILE_LENGTH - opts.start)
	if not qs.noByteServing?
		res.setHeader('Accept-Ranges', 'Bytes')
	if qs.failAt? and opts.start >= qs.failAt <= opts.end
		res.statusCode = 404
	fs.createReadStream(TEST_FILE, opts).on 'data', (data) ->
		if not data?
			return # hang forever; will cause socket timeout
		res.write data

describe 'resumable', ->
	before ->
		brokenServer.listen(TEST_PORT)

	after ->
		brokenServer.close()

	it 'should throw exception if url option is missing', (done) ->
		f = -> resumable({})
		expect(f).to.throw(Error)
		done()

	it 'should stream the whole response', (done) ->
		chunks = []
		resumable(request, { url: "http://localhost:#{TEST_PORT}/" })
		.on 'data', (data) ->
			chunks.push(data)
		.on 'end', ->
			expect(Buffer.concat(chunks)).to.eql(fs.readFileSync(TEST_FILE))
			done()

	it 'should stream the inner response', (done) ->
		chunks = []
		resumable(request, { url: "http://localhost:#{TEST_PORT}/" })
		.on 'response', (response) ->
			response
			.on 'data', (data) ->
				chunks.push(data)
		.on 'end', ->
			expect(Buffer.concat(chunks)).to.eql(fs.readFileSync(TEST_FILE))
			done()

	it 'should pipe the whole response', (done) ->
		resumable(request, { url: "http://localhost:#{TEST_PORT}/" })
		.pipe(fs.createWriteStream('/dev/null'))
		.on 'close', ->
			done()

	it 'should fail if treated as writable stream', (done) ->
		f = ->
			fs.createReadStream(TEST_FILE)
			.pipe(resumable(request, { url: "http://localhost:#{TEST_PORT}/" }))
		expect(f).to.throw(Error)
		done()

	expectError = (str, done, fn) ->
		error = null
		fn()
		.on 'error', (e) ->
			error = e
		.on 'end', ->
			expect(error.toString()).to.contain(str)
			done()

	it 'should fail if maxRetries are exceeded', (done) ->
		expectError 'Maximum retries exceeded', done, ->
			resumable(request, { url: "http://localhost:#{TEST_PORT}/?hang=1" })

	it 'should fail if no content-length is emitted', (done) ->
		expectError 'Cannot resume without Content-Length response header', done, ->
			resumable(request, { url: "http://localhost:#{TEST_PORT}/?noContentLength=1" })

	it 'should fail if no accept-ranges is emitted', (done) ->
		expectError 'Server does not support Byte Serving', done, ->
			resumable(request, { url: "http://localhost:#{TEST_PORT}/?noByteServing=1" })

	it 'should fail if some of the resumed requests return status code >= 400', (done) ->
		expectError 'Request failed with status code 404', done, ->
			resumable(request, { url: "http://localhost:#{TEST_PORT}/?failAt=#{TEST_FILE_LENGTH / 2}" })

	it 'should emit one "request" event', (done) ->
		requestEvents = []
		resumable(request, { url: "http://localhost:#{TEST_PORT}/" })
		.on 'request', (req) ->
			requestEvents.push(req)
		.on 'error', (e) ->
			done(e)
		.on 'end', ->
			expect(requestEvents.length).to.equal(1)
			expect(requestEvents).to.have.property(0).that.is.an.instanceof(http.ClientRequest)
			done()

	it 'should emit one "response" event', (done) ->
		responseEvents = []
		resumable(request, { url: "http://localhost:#{TEST_PORT}/" })
		.on 'response', (res) ->
			responseEvents.push(res)
		.on 'error', (e) ->
			done(e)
		.on 'end', ->
			expect(responseEvents.length).to.equal(1)
			expect(responseEvents).to.have.property(0).that.is.an.instanceof(stream.Readable)
			[ 'headers', 'httpVersion', 'method', 'rawHeaders', 'statusCode', 'statusMessage' ].forEach (prop) ->
				expect(responseEvents[0]).to.have.property(prop)
			done()

	it 'should report progress', (done) ->
		progressEvents = []
		resumable(request, { url: "http://localhost:#{TEST_PORT}/" }, { progressInterval: 10 })
		.on 'progress', (prog) ->
			progressEvents.push(prog)
		.on 'end', ->
			expect(progressEvents.length).to.be.greaterThan(0)
			expect(progressEvents[0]).to.have.property('percentage').that.equals(0)
			expect(progressEvents[progressEvents.length - 1]).to.have.property('percentage').that.equals(100)
			expect(progressEvents[progressEvents.length - 1]).to.have.deep.property('size.total').that.equals(TEST_FILE_LENGTH)
			expect(progressEvents[progressEvents.length - 1]).to.have.deep.property('size.transferred').that.equals(TEST_FILE_LENGTH)
			done()
