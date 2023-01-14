## To run these tests, simply execute `nimble test`.
## TODO :: add tests for different endpoints to display rate limiting for different endpoint

import clown_limiter, jester
import std / [unittest, httpclient, threadpool]
from std / nre import re
from std / jsonutils import toJson
from std / strutils import contains
from std / os import sleep

proc server() =

    routes:

        get "/":

            resp "home page"

        get "/apiendpoint.json":

            resp (status : true, msg : "opt successful").toJson()

        extend clown_limiter, "" ## can use second param of extend to further restrict clown limiter to certain endpoints

    runForever()

proc client429(url : string, totalreqs : int) : Future[bool] {.async.} =

    let client = newAsyncHttpClient()
    for pos in 1..totalreqs:

        let resp = await client.get(url)
        if pos == totalreqs and "429" in resp.status:

            result = true
            #break

    client.close()

proc client200(url : string, totalreqs : int) : Future[bool] {.async.} =

    result = true
    let client = newAsyncHttpClient()
    for pos in 1..totalreqs:

        let resp = await client.get(url)
        if "200" notin resp.status:

            result = false
            break

    client.close()

suite "multithreaded test suite":

    echo "starting test server..."
    spawn server()

    test "testing server for code 429 on surpassing api request rate":

        addLimiterEndpoints((nre.re "^/$", 51, 60))
        check:
            
            waitFor client429("http://localhost:5000/", 52)

    test "testing server for code 200 after cool down":

        echo "sleeping for 1 minute..."
        sleep(61 * 1000) ## sleep for 1 minute
        check:

            waitFor client200("http://localhost:5000/", 30)

    test "testing server for code 429 on surpassing api request rate again":

        echo "sleeping for 1 minute..."
        sleep(61 * 1000) ## sleep for 1 minute
        check:
            
            waitFor client429("http://localhost:5000/", 52)

    test "testing rate limit for regex specified pattern":

        addLimiterEndpoints((nre.re "([/]|[A-z])+(.json)$", 51, 60)) ## only limit endpoints ending with `.json`
        ## and limit those endpoints by 50 rates per 60 seconds
        check:
            
            waitFor client429("http://localhost:5000/apiendpoint.json", 52)
            