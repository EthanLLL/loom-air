# The Loom app's server: a TCP forwarder from the app's port to Air's own.
#   python3 scripts/forward.py <listen port> <Air's port>
# Air runs as a service of its own, always up for the tunnel; a Loom app with proxy "all" must have a server,
# and its server is socket-activated and stopped when idle. So the app runs this, which forwards byte for byte
# (WebSockets too) to Air on 127.0.0.1. Standard library only.
import asyncio, sys

LISTEN, TARGET = int(sys.argv[1]), int(sys.argv[2])


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def serve(client_r, client_w):
    try:
        air_r, air_w = await asyncio.open_connection("127.0.0.1", TARGET)
    except OSError:
        client_w.close()
        return
    await asyncio.gather(pipe(client_r, air_w), pipe(air_r, client_w))


async def main():
    server = await asyncio.start_server(serve, "127.0.0.1", LISTEN)
    async with server:
        await server.serve_forever()


asyncio.run(main())
