type
    
    RateStatus* {.pure.} = enum

        NotExceeded Exceeded Expired

    RequestRate* = object

        ip* : string
        calls*, lastcalled* : int