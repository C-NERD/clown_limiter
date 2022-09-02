import jester, clown_limiter/tracker
from re import re, contains, Regex

export tracker, re

## sequence of data for endpoints which would be limited
## the sequence contains tuples with endpoint pattern, rate and freq in seconds
## do not mutate the variable limiter_data directly but instead use the
## addLimiterEndpoints procedure. Seriously don't mutate this variable directly 👀👀
var clown_limiter_data_do_not_touch* : seq[tuple[pattern : Regex, rate, freq : int]] = @[
    (re".+", 50, 60)
]

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

