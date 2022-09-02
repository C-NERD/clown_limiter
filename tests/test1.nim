# To run these tests, simply execute `nimble test`.

import unittest, httpclient, threadpool, clown_limiter, jester
from std / jsonutils import toJson
from strutils import contains

setRate(50) ## set api request rate to 50 requests
setFreq(60) ## set api rate frequency to 60 seconds
## Avoid setting rate and frequency multiple times and in threaded procedures

proc server() =

    routes:

        get "/":

            resp "home page"

        get "/userpage":

            resp "userpage"

        post "/apiendpoint/json1":

            resp (status : true, msg : "opt successful").toJson()

        put "/apiendpoint/json2":

            resp (status : true, msg : "opt failed").toJson()

        extend clown_limiter, ""

    runForever()

proc client() : Future[bool] {.async.} =

    let client = newAsyncHttpClient()
    #await sleepAsync(1000 * 10) ## waits 10 seconds for server to start
    for _ in 1..51:

        let resp = await client.get("http://localhost:5000/")
        if "429" in resp.status:

            return true

suite "multithreaded test suite":

    setup:

        echo "starting test server on 2 threads..."
        spawn server()
        spawn server()

    test "testing server for code 429 on surpassing api request rate":

        check:

            waitFor client()
