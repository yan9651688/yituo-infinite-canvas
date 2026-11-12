#!/usr/bin/env python3
"""Codex 汉化通道：CONNECT 白名单代理，同时提供下载站与易拓画布转发。

背景见 constant/codex_i18n.go：Codex 桌面版靠 https://ab.chatgpt.com/v1/initialize 下发
多语言开关，国内直连不通，所以安装器写一条只覆盖这个域名的 PAC，指向本程序。

设计原则（改动前请先想清楚）：
  * 白名单只有一个目标 ab.chatgpt.com:443。别的域名、别的端口一律 403，
    所以它不是开放代理，被扫描到也没有价值，流量也只会是几 KB。
  * 只做 TCP 隧道，不解密、不改写，TLS 从客户端一直通到 OpenAI。
  * /comic/ 仅转发 GET/HEAD；/infinite-canvas 与 /api/ 支持画布所需的双向 HTTP 转发。
  * 目标地址由本机解析，不信任客户端给的 IP。
  * 只通告 http/1.1，保证 Chromium 用最普通的 CONNECT 握手。
  * 每行日志只记：时间、客户端 IP、结果、耗时。不记任何内容。

用法：
  python3 i18n_connect_proxy.py --cert fullchain.pem --key privkey.pem --port 443 --port 8899
收到 SIGHUP 时重新加载证书（续期后不用重启）。
"""
import argparse
import asyncio
import logging
import signal
import ssl
import time

ALLOWED_HOST = "ab.chatgpt.com"
ALLOWED_PORT = 443

HEADER_LIMIT = 8192        # 请求头最大字节数
HANDSHAKE_TIMEOUT = 10     # 等客户端发完 CONNECT 请求的时间（秒）
UPSTREAM_TIMEOUT = 10      # 连接 OpenAI 的超时（秒）
IDLE_TIMEOUT = 60          # 隧道里双向都没数据多久就断开（秒）
MAX_LIFETIME = 120         # 单条隧道最长存活时间（秒），开关请求用不到这么久
MAX_CONNECTIONS = 400      # 全局并发上限
MAX_PER_IP = 30            # 单个客户端 IP 并发上限

log = logging.getLogger("i18n-proxy")

active_total = 0
active_by_ip = {}


async def reply(writer, status_line):
    try:
        writer.write(
            ("HTTP/1.1 %s\r\nConnection: close\r\nContent-Length: 0\r\n\r\n" % status_line).encode("ascii")
        )
        await asyncio.wait_for(writer.drain(), 5)
    except Exception:
        pass


async def pump(reader, writer, idle_timeout=IDLE_TIMEOUT):
    """单向搬运数据，直到对端关闭、出错或空闲超时。"""
    try:
        while True:
            data = await asyncio.wait_for(reader.read(65536), idle_timeout)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (asyncio.TimeoutError, ConnectionError, OSError, ssl.SSLError):
        pass


async def relay_http(reader, writer, head, up_r, up_w, idle_timeout, bidirectional=False):
    up_w.write(head)
    await up_w.drain()
    pipes = [asyncio.ensure_future(pump(up_r, writer, idle_timeout))]
    if bidirectional:
        pipes.append(asyncio.ensure_future(pump(reader, up_w, idle_timeout)))
    try:
        await asyncio.wait(pipes, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for pipe in pipes:
            pipe.cancel()


async def close_quietly(writer):
    try:
        writer.close()
        await asyncio.wait_for(writer.wait_closed(), 3)
    except Exception:
        pass


async def handle(reader, writer):
    global active_total
    peer = writer.get_extra_info("peername")
    ip = peer[0] if peer else "-"
    started = time.monotonic()
    result = "error"
    up_w = None
    counted = False
    try:
        if active_total >= MAX_CONNECTIONS or active_by_ip.get(ip, 0) >= MAX_PER_IP:
            result = "busy"
            await reply(writer, "503 Service Unavailable")
            return
        active_total += 1
        active_by_ip[ip] = active_by_ip.get(ip, 0) + 1
        counted = True

        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), HANDSHAKE_TIMEOUT)
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError,
                ConnectionError, OSError, ssl.SSLError):
            result = "bad_request"
            return

        request_line = head.split(b"\r\n", 1)[0].decode("latin-1")
        parts = request_line.split()
        path = parts[1].split("?", 1)[0] if len(parts) == 3 else ""
        if len(parts) == 3 and (path == "/infinite-canvas" or path.startswith("/infinite-canvas/") or path.startswith("/api/")):
            try:
                up_r, up_w = await asyncio.wait_for(
                    asyncio.open_connection("127.0.0.1", MIRROR_PORT), UPSTREAM_TIMEOUT
                )
                await relay_http(reader, writer, head, up_r, up_w, 3600, bidirectional=True)
                result = "canvas"
            except (asyncio.TimeoutError, OSError):
                result = "canvas_fail"
                await reply(writer, "502 Bad Gateway")
            return

        if len(parts) == 3 and parts[0].upper() in ("GET", "HEAD") and parts[1].startswith("/comic/"):
            try:
                up_r, up_w = await asyncio.wait_for(
                    asyncio.open_connection("127.0.0.1", MIRROR_PORT), UPSTREAM_TIMEOUT
                )
                await relay_http(reader, writer, head, up_r, up_w, IDLE_TIMEOUT)
                result = "comic_mirror"
            except (asyncio.TimeoutError, OSError):
                result = "mirror_fail"
                await reply(writer, "502 Bad Gateway")
            return

        if len(parts) != 3 or parts[0].upper() != "CONNECT":
            result = "not_connect"
            await reply(writer, "405 Method Not Allowed")
            return

        host, _, port = parts[1].rpartition(":")
        if host.lower().rstrip(".") != ALLOWED_HOST or port != str(ALLOWED_PORT):
            result = "denied"
            await reply(writer, "403 Forbidden")
            return

        try:
            up_r, up_w = await asyncio.wait_for(
                asyncio.open_connection(ALLOWED_HOST, ALLOWED_PORT), UPSTREAM_TIMEOUT
            )
        except (asyncio.TimeoutError, OSError):
            result = "upstream_fail"
            await reply(writer, "502 Bad Gateway")
            return

        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await writer.drain()
        pipes = [
            asyncio.ensure_future(pump(reader, up_w)),
            asyncio.ensure_future(pump(up_r, writer)),
        ]
        try:
            await asyncio.wait(pipes, timeout=MAX_LIFETIME, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for pipe in pipes:
                pipe.cancel()
        result = "ok"
    except Exception as exc:  # 任何单条连接的异常都不能影响其它连接
        result = "error:%s" % type(exc).__name__
    finally:
        if counted:
            active_total -= 1
            left = active_by_ip.get(ip, 1) - 1
            if left <= 0:
                active_by_ip.pop(ip, None)
            else:
                active_by_ip[ip] = left
        if up_w is not None:
            await close_quietly(up_w)
        await close_quietly(writer)
        log.info("connect ip=%s result=%s ms=%d", ip, result, int((time.monotonic() - started) * 1000))


async def main():
    global MIRROR_PORT
    ap = argparse.ArgumentParser(description="Codex 汉化通道与易拓画布代理")
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--port", type=int, action="append", required=True, help="可重复，如 --port 443 --port 8899")
    ap.add_argument("--host", default=None, help="监听地址，默认全部")
    ap.add_argument("--mirror-port", type=int, default=8898, help="本机 Nginx 监听端口")
    args = ap.parse_args()
    MIRROR_PORT = args.mirror_port

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.set_alpn_protocols(["http/1.1"])
    ctx.load_cert_chain(args.cert, args.key)

    def reload_cert():
        try:
            ctx.load_cert_chain(args.cert, args.key)
            log.info("cert reloaded")
        except Exception as exc:
            log.error("cert reload failed: %s", exc)

    loop = asyncio.get_running_loop()
    try:
        loop.add_signal_handler(signal.SIGHUP, reload_cert)
    except NotImplementedError:
        pass

    servers = []
    for port in args.port:
        servers.append(await asyncio.start_server(
            handle, host=args.host, port=port, ssl=ctx, limit=HEADER_LIMIT, backlog=256
        ))
        log.info("listening on port %d, allow only %s:%d", port, ALLOWED_HOST, ALLOWED_PORT)
    await asyncio.gather(*[s.serve_forever() for s in servers])


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
