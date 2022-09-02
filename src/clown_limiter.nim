import jester, clown_limiter/tracker
from re import re

export tracker, re

router clown_limiter:

    before re".+":
        ## rate limiting endpoint
        
        let 
            ip = request.ip()
            rateinfo = ip.rateStatus()
            
        case rateinfo.status

        of Exceeded:

            halt Http429

        of NotExceeded:

            ip.recordReqRate(rateinfo.calls)

        of Expired:

            ip.resetReqRate()
