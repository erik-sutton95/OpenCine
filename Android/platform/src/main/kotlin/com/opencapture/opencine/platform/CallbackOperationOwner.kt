package com.opencapture.opencine.platform

/** Identity fence for callbacks, queued starts and cancellation across reconnects. */
class CallbackOperationOwner<Resource : Any> {
    class Token<Resource : Any> {
        @Volatile var resource: Resource? = null
            internal set
    }

    private var current: Token<Resource>? = null

    @Synchronized
    fun begin(): Token<Resource> = Token<Resource>().also { current = it }

    @Synchronized
    fun current(): Token<Resource>? = current

    @Synchronized
    fun attach(token: Token<Resource>, resource: Resource) {
        if (current === token) token.resource = resource
    }

    /** Drops [token]'s resource: its callbacks no longer match. */
    @Synchronized
    fun detach(token: Token<Resource>) {
        token.resource = null
    }

    @Synchronized
    fun runIfCurrent(token: Token<Resource>, resource: Resource? = null, action: () -> Unit): Boolean {
        if (current !== token || (resource != null && token.resource !== resource)) return false
        action()
        return true
    }

    @Synchronized
    fun finish(token: Token<Resource>) {
        if (current === token) current = null
    }
}
