package app.aiplayer.aiplayer

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI

fun main() {
    fun http(host: String, port: Int) = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(host, port))
    check(SystemProxyResolver.configuration(listOf(Proxy.NO_PROXY)) == "DIRECT")
    check(SystemProxyResolver.configuration(listOf(http("proxy.example", 8080), Proxy.NO_PROXY)) ==
        "PROXY proxy.example:8080; DIRECT")
    check(SystemProxyResolver.configuration(listOf(http("::1", 7890))) == "PROXY [::1]:7890")
    val visits = mutableListOf<URI>()
    var current = http("first.example", 3128)
    val selector = object : ProxySelector() {
        override fun select(uri: URI): List<Proxy> {
            visits += uri
            return if (uri.host == "excluded.example") listOf(Proxy.NO_PROXY) else listOf(current)
        }
        override fun connectFailed(uri: URI, address: SocketAddress, exception: IOException) = Unit
    }
    val target = "https://api.bgm.tv/v0/subjects/611077?lang=zh"
    check(SystemProxyResolver.resolve(target, selector) == "PROXY first.example:3128")
    check(visits.single().toString() == target)
    current = http("changed.example", 8080)
    check(SystemProxyResolver.resolve(target, selector) == "PROXY changed.example:8080")
    check(SystemProxyResolver.resolve("https://excluded.example/private/path", selector) == "DIRECT")
    check(SystemProxyResolver.resolve(target, null) == "DIRECT")
    check(runCatching {
        SystemProxyResolver.configuration(listOf(Proxy(Proxy.Type.SOCKS,
            InetSocketAddress.createUnresolved("proxy.example", 1080))))
    }.exceptionOrNull() is UnsupportedOperationException)
    for (invalid in listOf("file:///private", "https://user:password@private.example/", "https://private.example/#fragment")) {
        check(runCatching { SystemProxyResolver.resolve(invalid, selector) }.isFailure)
    }
    check(runCatching { SystemProxyResolver.configuration(listOf(http("host; DIRECT", 8080))) }.isFailure)
    println("SystemProxyResolver: direct, HTTP, IPv6, ordered fallback, URL-dependent selection, live changes, exclusions and invalid settings passed")
}
