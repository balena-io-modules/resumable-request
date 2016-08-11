http = require 'http'
fs = require 'fs'
progress = require 'request-progress'
Range = require('http-range').Range
resumable = require '../'
{ expect } = require 'chai'
request = require 'request'
url = require 'url'

TEST_PORT = process.env.TEST_PORT ? 5000
TEST_FILE = './test/test.html'
TEST_FILE_LENGTH = 128086
TEST_BROKEN_RESPONSE_SIZE = 20000

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
	if not qs.noContentLength?
		res.setHeader('Content-length', TEST_FILE_LENGTH - opts.start)
	if qs.failAt? and opts.start >= qs.failAt <= opts.end
		res.statusCode = 404
	fs.createReadStream(TEST_FILE, opts).pipe(res)

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

	it 'should fail if maxRetries are exceeded', (done) ->
		resumable(request, { url: "http://localhost:#{TEST_PORT}/" }, { maxRetries: 2 })
		.on 'error', ->
			done()
		.on 'end', ->
			done(new Error('end should not have been called'))

	it 'should fail if no content-length is emitted', (done) ->
		resumable(request, { url: "http://localhost:#{TEST_PORT}/?noContentLength=1" })
		.on 'error', ->
			done()
		.on 'end', ->
			done(new Error('end should not have been called'))

	it 'should fail if some of the resumed requests return status code >= 400', (done) ->
		resumable(request, { url: "http://localhost:#{TEST_PORT}/?failAt=#{TEST_FILE_LENGTH / 2}" })
		.on 'error', ->
			done()
		.on 'end', ->
			done(new Error('end should not have been called'))

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
			expect(responseEvents).to.have.property(0).that.is.an.instanceof(http.IncomingMessage)
			done()

	it 'should be compatible with request-progress', (done) ->
		progressEvents = []
		progress resumable(request, { url: "http://localhost:#{TEST_PORT}/" }), { throttle: 0 }
		.on 'progress', (prog) ->
			# "cheap" deep copy
			# otherwise all progress events are the same
			copyProg = JSON.parse(JSON.stringify(prog))
			progressEvents.push(copyProg)
		.on 'end', ->
			expect(progressEvents.length).to.be.greaterThan(0)
			expect(progressEvents[0]).to.have.property('percentage').greaterThan(0)
			expect(progressEvents[progressEvents.length - 1]).to.have.property('percentage').that.equals(1)
			expect(progressEvents[progressEvents.length - 1]).to.have.deep.property('size.total').that.equals(TEST_FILE_LENGTH)
			expect(progressEvents[progressEvents.length - 1]).to.have.deep.property('size.transferred').that.equals(TEST_FILE_LENGTH)
			done()
		.pipe(fs.createWriteStream('/dev/null'))
