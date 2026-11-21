#!/usr/bin/env python3
"""Exercise wheel cadence, burst boundaries and input ordering in a real PTY."""
import importlib.util, fcntl, json, os, pathlib, pty, re, select, struct, subprocess, tempfile, termios, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
DOWN, UP = b'\x1b[<65;20;10M', b'\x1b[<64;20;10M'
spec = importlib.util.spec_from_file_location('terminal_screen', ROOT/'scripts/checks/terminal-layout-check.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
screen = module.Screen(80,24)

with tempfile.TemporaryDirectory(prefix='bookslide-mouse-') as temp:
    root = pathlib.Path(temp)
    book = root/'fixture.epub'
    (book/'META-INF').mkdir(parents=True)
    (book/'META-INF/container.xml').write_text('<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>')
    (book/'content.opf').write_text('<package><metadata><title>Mouse fixture</title></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>')
    (book/'one.xhtml').write_text('<html><body>'+''.join(f'<p>Line {i:04d}: continuous reading.</p>' for i in range(300))+'</body></html>')
    state = root/'state'
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH',24,80,0,0))
    process = subprocess.Popen([os.environ.get('BOOKSLIDE_EXECUTABLE', str(pathlib.Path.home()/'Library/Caches/AppleProjectBuilds/book-slide/swift/debug/bookslide')),str(book),'--no-remote'],stdin=slave,stdout=slave,stderr=slave,env=dict(os.environ,TERM='xterm-256color',BOOKSLIDE_TERMINAL_STATE_DIR=str(state)))
    os.close(slave)

    def read(timeout=0.3):
        result = b''
        end = time.monotonic()+timeout
        while time.monotonic()<end:
            if select.select([master],[],[],min(0.03,max(0,end-time.monotonic())))[0]:
                try: result += os.read(master,65536)
                except OSError: break
            elif result: break
        screen.feed(result)
        return result

    def send(data):
        os.write(master,data)
        return read()

    def position(data):
        # Read the actual visible body, independent of removed status counters.
        first = ''.join(c[0] for c in screen.grid[3]).strip()
        second = ''.join(c[0] for c in screen.grid[4]).strip()
        found = re.search(r'Line (\d{4}):', first or second)
        assert found, screen.text()
        return int(found[1])*2 + (1 if first else 0)

    try:
        assert position(read(15)) == 1
        assert position(send(DOWN)) == 2, 'one wheel event is one line'
        assert position(send(UP)) == 1, 'reverse is immediate'
        # Beyond the former 128-byte boundary: all movement, one paint.
        burst = send(DOWN*24)
        assert position(burst) == 25
        assert burst.count(b'\x1b[?2026h') == 1, 'queued wheel burst paints once'
        assert position(send(UP*24)) == 1
        cancelled = send(UP*4+DOWN*4)
        assert b'\x1b[?2026h' not in cancelled, 'opposite queued deltas cancel even at the book boundary'
        # An incomplete SGR packet must survive a read boundary.
        assert b'\x1b[?2026h' not in send(DOWN[:7])
        assert position(send(DOWN[7:])) == 2
        assert position(send(UP)) == 1
        # A key separates wheel batches; its action must not be drained away.
        assert position(send(UP+b'j'+DOWN)) == 3
        assert position(send(UP*2)) == 1
        assert '目录' in send(DOWN+b'c').decode()
        send(UP*3)
        assert position(send(b'c')) == 2, 'wheel movement applies before entering contents'
        # Stream distinct events at roughly 120 Hz, reading each complete frame.
        for expected in range(3,23):
            began = time.monotonic()
            os.write(master,DOWN)
            frame = b''
            while b'\x1b[?2026l' not in frame:
                assert select.select([master],[],[],1)[0], 'wheel input must render promptly'
                frame += os.read(master,65536)
            screen.feed(frame)
            assert position(frame) == expected
            assert b'\x1b[1S' in frame and frame.count(b'\x1b[2K') <= 3
            time.sleep(max(0,1/120-(time.monotonic()-began)))
        assert not read(0.25), 'no added mouse animation after input stops'
        # Keep input ordering through a mode switch and back.
        send(DOWN+b'm'); assert (state/'view-mode').read_text() == 'paged'
        restored = position(send(b'm'))
        assert 1 <= restored <= 23, 'pagination may align the anchor to a page start'
        assert position(send(DOWN)) == restored+1
        send(DOWN+b'q'); process.wait(timeout=5)
        values = [json.loads(p.read_text()) for p in state.glob('*.json')]
        saved = next(v for v in values if isinstance(v,dict) and 'chapter' in v)
        assert saved['offset'] > 0 and process.returncode == 0, 'wheel immediately before quit is saved'
        print('PASS: single-line wheel, 24-event/312-byte burst in one frame, boundary cancellation, split SGR packet, keyboard/menu/mode ordering, 120 Hz stream, no trailing animation, quit durability')
    finally:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
        os.close(master)
