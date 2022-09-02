## To run these tests, simply execute `nimble test`.

import unittest, httpclient, threadpool, clown_limiter, jester
from std / jsonutils import toJson
from strutils import contains

proc server() =

    routes:

        get "/":

            resp "home page"

        get "/userpage":

            resp "userpage"

        post "/apiendpoint.json":

            resp (status : true, msg : "opt successful").toJson()

        put "/apiendpoint.json":

            resp (status : true, msg : "opt failed").toJson()

        extend clown_limiter, "" ## can use extend second param to further restrict clown limiter to certain endpoints

    runForever()

proc client() : Future[bool] {.async.} =

    let client = newAsyncHttpClient()
    #await sleepAsync(1000 * 10) ## waits 10 seconds for server to start
    for _ in 1..51:

        let resp = await client.get("http://localhost:5000/")
        if "429" in resp.status:

            return true

proc clientTwo() : Future[bool] {.async.} =

    let 
        client = newAsyncHttpClient()
        resp = await client.post("http://localhost:5000/apiendpoint.json")

    if "429" in resp.status:

        return true

suite "multithreaded test suite":

    echo "starting test server on 2 threads..."
    spawn server()
    spawn server()

    test "testing server for code 429 on surpassing api request rate":

        check:

            waitFor client()

    test "testing rate limit for regex specified pattern":

        addLimiterEndpoints(@[(re"([/]|[A-z])+(.json)$", 50, 60)]) ## only limit endpoints ending with `.json`
        check: 
            not waitFor client()
            waitFor clientTwo()
