# Copyright (C) 2022 Cnerd
# MIT License - Look at license.txt for details.
##[
    Jester plugin for api rate limiting. This plugin is built to work on single and multithreaded jester servers. 
    This plugin makes use of a sqlite in memory instance, since this should not be bounded to the nim `gc` 
    and the db's write operations are controlled by locks to prevent data corruption. This plugin is safe 
    to be used in single and mutithreaded instances

    Examples
    ========

    .. code-block:: nim
        import threadpool, clown_limiter, jester
        from std / jsonutils import toJson

        addLimiterEndpoints(@[(re"([/]|[A-z])+(.json)$", 50, 60)]) ## only limit endpoints ending with `.json`
        ## and limit those endpoints by 50 rates per 60 seconds. Do not call this in a threaded proc

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

                extend clown_limiter, "" ## can use second param of extend to further restrict clown limiter 
                ## to certain endpoints

            runForever()

        spawn server()
        spawn server()
        sync()]##

import jester, clown_limiter/tracker
from re import re, contains, Regex

export tracker, re

var clown_limiter_data_do_not_touch* : seq[tuple[pattern : Regex, rate, freq : int]] = @[
    (re".+", 50, 60)
] ## Do not mutate this variable directly 👀👀, but instead use the addLimiterEndpoints proc

proc addLimiterEndpoints*(data : seq[tuple[pattern : Regex, rate, freq : int]]) =
    ## sets the data for api endpoints to be rate limited.
    ## this procedure directly mutates a variable so avoid calling it inside of a threaded procedure

    clown_limiter_data_do_not_touch = data

router clown_limiter:

    before re".+":
        ## rate limiting endpoint
        
        {.cast(gcsafe).}:
            let data = clown_limiter_data_do_not_touch

        var 
            check_rate : bool = false
            rate, freq : int
        let url = request.path()
        for info in data:

            if contains(url, info.pattern):

                check_rate = true
                rate = info.rate
                freq = info.freq
                break
        
        if check_rate:

            let 
                ip = request.ip()
                rateinfo = ip.rateStatus(rate, freq)
                
            case rateinfo.status

            of Exceeded:

                halt Http429

            of NotExceeded:

                ip.recordReqRate(rateinfo.calls)

            of Expired:

                ip.resetReqRate()

