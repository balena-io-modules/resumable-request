# resumable-request
Resumable requests with node.js

It allows you to continue long streaming requests even if they get interrupted by network errors. In order for requests to be resumable, the server __must__ respond with Content-length header and support [HTTP Range request header](https://en.wikipedia.org/wiki/List_of_HTTP_header_fields#range-request-header).

This is ideal for setups with flaky network issuing requests with large output that needs to be downloaded and processed as a stream.

The request is resumed immediately, and there is no disk persistency, therefore there will be no resuming if the process was terminated and the request reinstated. For resumable downloads, use a download manager utility such as [fast-download package](https://www.npmjs.com/package/fast-download).

## Installation

```
$ npm install --save resumable-request
```

## Usage

```
request = require('request');
resumable = require('resumable-request');

resumable(request, { url: "http://example.org/" })
.pipe(fs.createWriteStream('out.txt'));
```

## Documentation

### resumable(request, requestOpts, resumableOpts = { maxRetries = 10 })

Initiate a resumable request. Each request is executed using the __request__ module, passing __requestOpts__.

For requestOpts refer to the options in the documentation of [request](https://github.com/request/request) module.

__resumableOpts__ is an optional object describing the options handled by resumable itself:
 * __maxRetries__: Maximum times to retry a request. (default: 10)

## Why does resumable need "request" module as an argument?

This way you can use any version of "request" module you want, granted it has the same output. Any version within the same major version (2.x.x) should work, but also potentially any other module that has compatible output. Also, this lowers the footprint of this module for all projects that already require "request" module.
