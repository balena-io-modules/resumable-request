# resumable-request
Resumable requests with node.js

It allows you to continue long streaming requests even if they get interrupted by network errors. In order for requests to be resumable, the server __must__ respond with `Content-Length` and `Accept-Ranges: bytes` headers and support [Range requests](https://en.wikipedia.org/wiki/Byte_serving).

This is ideal for setups with flaky network issuing requests with large output that needs to be downloaded and processed as a stream.

The request is resumed immediately, and there is no disk persistency, therefore there will be no resuming if the process was terminated and the request reinstated. For resumable downloads, use a download manager utility such as [fast-download package](https://www.npmjs.com/package/fast-download).

## Installation

```
$ npm install --save resumable-request
```

## Usage

```js
var request = require('request');
var resumable = require('resumable-request');

resumable(request, { url: "http://example.org/" })
  .pipe(fs.createWriteStream('out.txt'));
```

## Documentation

### resumable(request, requestOpts, resumableOpts)

Initiate a resumable request. Each request is executed using the __request__ module, passing __requestOpts__.

For requestOpts refer to the options in the documentation of [request](https://github.com/request/request) module.

__resumableOpts__ is an optional object describing the options handled by resumable itself:
 * __maxRetries__: Maximum times to retry a request. (default: 10)
 * __retryInterval__: The time to wait before retrying a failed request, in milliseconds. (default: 1000)
 * __progressInterval__: The interval between reporting progress with `progress` events, in milliseconds. (default: 1000)

### resumable.defaults(resumableOpts)

Returns a wrapper around the normal resumable API that defaults to whatever options you pass to it.

For example:

```js
var baseResumable = resumable.defaults({
  maxRetries: 5,
  retryInterval: 100,
  progressInterval: 2000
})

// You may override defaults inline with the request. The following will
// report progress every 500ms, instead of 2000ms that was specified above.
baseResumable(request, { url: "http://example.org/" }, { progressInterval: 500 })
  .pipe(fs.createWriteStream('out.txt'));
```

### `progress` Event

You can follow the download progress by registering a function for the `progress` event on the resumable request instance. The function will be called with a single argument in an interval (as specified by the `progressInterval` resumable request option), that has the following form:

```js
{
  percentage: 50,          // Overall progress as an integer in the range [0, 100]
  size: {
    transferred: 27610959  // The transferred response body size in bytes
    total: 90044871,       // The total response body size in bytes
  }
}
```

For example:

```js
resumable(request, { url: "http://example.org/" }, { progressInterval: 2000 })
  .on('progress', function onProgress(state) {
    console.log(state);
  })
  .pipe(fs.createWriteStream('out.txt'));
```

## Why does resumable need "request" module as an argument?

This way you can use any version of "request" module you want, granted it has the same output. Any version within the same major version (2.x.x) should work, but also potentially any other module that has compatible output. Also, this lowers the footprint of this module for all projects that already require "request" module.
