#!/usr/bin/env python3
"""Measure input-to-render on a long chapter; use only isolated reading state."""
import fcntl, json, os, pathlib, pty, select, statistics, struct, subprocess, tempfile, termios, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='bookslide-latency-') as temp:
    root = pathlib.Path(temp)
    book = root/'long.epub'
    (book/'META-INF').mkdir(parents=True)
    (book/'META-INF/container.xml').write_text('<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>')
    (book/'content.opf').write_text('<package><metadata><title>Latency fixture</title></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>')
    (book/'one.xhtml').write_text('<html><body>' + ''.join(f'<p>第{i}段。'+('连续阅读文字，检查滚动响应。'*12)+'</p>' for i in range(1000)) + '</body></html>')
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH',24,80,0,0))
    state = root/'state'
    process = subprocess.Popen([os.environ.get('BOOKSLIDE_EXECUTABLE', str(pathlib.Path.home()/'Library/Caches/AppleProjectBuilds/book-slide/swift/debug/bookslide')),str(book),'--no-remote'],stdin=slave,stdout=slave,stderr=slave,env=dict(os.environ,TERM='xterm-256color',BOOKSLIDE_TERMINAL_STATE_DIR=str(state)))
    os.close(slave)
    def output(timeout):
        result = b''
        end = time.monotonic()+timeout
        while time.monotonic()<end:
            ready,_,_ = select.select([master],[],[],min(0.03,max(0,end-time.monotonic())))
            if ready:
                try: result += os.read(master,65536)
                except OSError: break
            elif result: break
        return result
    try:
        assert 'Latency fixture' in output(30).decode(), 'long book opens'
        times=[]
        for _ in range(30):
            began=time.monotonic(); os.write(master,b'j')
            ready,_,_=select.select([master],[],[],2)
            assert ready, 'input produces a frame'
            data=os.read(master,65536)
            times.append((time.monotonic()-began)*1000)
            assert b'\x1b[2J' not in data, 'movement must not clear the screen'
            assert b'\x1b[1S' in data, 'single-line scroll reuses terminal rows'
            assert data.count(b'\x1b[2K') <= 3, 'only exposed text and changed status rows are repainted'
            assert b'\x1b[?2026h' in data and b'\x1b[?2026l' in data, 'frame is presented as one synchronized update'
            output(0.035)
        # One input packet moves all ten lines but renders one final status row.
        os.write(master,b'jjjjjjjjjj'); burst=output(1)
        assert burst.count(b'\x1b[?2026h')==1, 'burst must coalesce rendering'
        assert b'\x1b[10S' in burst, 'every burst movement applied'
        # Quit in the same packet as the final movement, before the save timer fires.
        os.write(master,b'jq'); output(2); process.wait(timeout=5)
        records=[json.loads(p.read_text()) for p in (state/'Progress').glob('*.json')]
        values=[json.loads(p.read_text()) for p in state.glob('*.json')]
        positions=[value for value in values if isinstance(value,dict) and 'chapter' in value]
        assert records and records[0]['anchor']['fraction']>0 and positions[0]['offset']>0, f'quit flushes both position formats: records={records}, positions={positions}'
        print(f'PASS: long chapter; 30 input-to-render samples median={statistics.median(times):.1f}ms max={max(times):.1f}ms; burst coalescing; no full clears; immediate quit durability')
    finally:
        if process.poll() is None: process.terminate(); process.wait(timeout=5)
        os.close(master)
