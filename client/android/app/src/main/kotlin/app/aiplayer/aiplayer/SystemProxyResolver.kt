package app.aiplayer.aiplayer

import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI

/** java.net's current selector owns Android's static exclusions and PAC rules.
 * Do not cache its answers: PAC can depend on the full URL and current network. */
internal object SystemProxyResolver {
    fun resolve(url: String, selector: ProxySelector? = ProxySelector.getDefault()): String {
        require(url.length <= 16384)
        val uri = URI(url)
        require(uri.scheme == "http" || uri.scheme == "https")
        require(!uri.host.isNullOrBlank() && uri.userInfo == null && uri.fragment == null)
        return configuration(selector?.select(uri) ?: listOf(Proxy.NO_PROXY))
    }

    fun configuration(proxies: List<Proxy>): String {
        require(proxies.isNotEmpty() && proxies.size <= 32)
        return proxies.map { proxy ->
            when (proxy.type()) {
                Proxy.Type.DIRECT -> "DIRECT"
                Proxy.Type.HTTP -> {
                    val address = proxy.address() as? InetSocketAddress
                        ?: throw IllegalArgumentException()
                    // hostString never performs the reverse DNS lookup of hostName.
                    val host = address.hostString
                    require(host.isNotBlank() && host.length <= 253 &&
                        host.none { it.isWhitespace() || it in ";/@?#\\" } &&
                        address.port in 1..65535)
                    val formatted = if (host.contains(':') && !host.startsWith('['))
                        "[$host]" else host
                    // Dart HttpClient uses HTTP CONNECT for an HTTPS target.
                    "PROXY $formatted:${address.port}"
                }
                else -> throw UnsupportedOperationException()
            }
        }.distinct().joinToString("; ")
    }
}
