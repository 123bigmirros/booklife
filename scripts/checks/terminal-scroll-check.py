#!/usr/bin/env python3
"""Exercise the real CLI in an isolated PTY without touching user progress."""
import fcntl, json, os, pathlib, pty, select, signal, struct, subprocess, tempfile, termios, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='bookslide-scroll-') as directory:
    def start(*extra):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH',24,80,0,0))
        env = dict(os.environ, TERM='xterm-256color', BOOKSLIDE_TERMINAL_STATE_DIR=directory)
        process = subprocess.Popen([os.environ.get('BOOKSLIDE_EXECUTABLE', str(pathlib.Path.home()/'Library/Caches/AppleProjectBuilds/book-slide/swift/debug/bookslide')),str(ROOT/'Sources/BookSlideMac/Resources/Reader/QuietHours.epub'),'--no-remote',*extra], stdin=slave,stdout=slave,stderr=slave,env=env)
        os.close(slave)
        return master, process
    def read(master):
        data = b''; until = time.monotonic()+2
        while time.monotonic()<until:
            ready,_,_ = select.select([master],[],[],0.3)
            if not ready:
                if data: break
                continue
            try: data += os.read(master,65536)
            except OSError: break
        return data.decode('utf-8',errors='replace')
    def key(master, value):
        os.write(master,value); return read(master)
    def location():
        for path in pathlib.Path(directory).glob('*.json'):
            value = json.loads(path.read_text())
            if isinstance(value,dict) and 'chapter' in value: return value
        raise AssertionError('No saved position')
    master, process = start()
    try:
        assert '? 帮助' in read(master), 'minimal reader opens'
        key(master,b'j'); one=location(); assert one['offset']>0
        key(master,b'k'); assert location()['offset']==0, 'reverse one line'
        key(master,b'\x1b[<65;20;10M'); wheel=location(); assert wheel==one, 'one wheel event matches one keyboard line'
        key(master,b' '); screen=location(); assert screen!=wheel, 'overlapping screen movement'
        key(master,b'm')
        assert pathlib.Path(directory,'view-mode').read_text()=='paged'
        key(master,b' '); before=location()
        key(master,b'm'); assert pathlib.Path(directory,'view-mode').read_text()=='scroll'
        assert location()['chapter']==before['chapter'], 'mode switch keeps chapter'
        anchor=location()
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH',28,68,0,0)); process.send_signal(signal.SIGWINCH); read(master)
        # Save after a no-op boundary-free mode switch, then return to scroll.
        key(master,b'm'); key(master,b'm')
        assert location()['chapter']==anchor['chapter'], 'resize keeps chapter'
        saved=location()
        output=key(master,b'jq'); process.wait(timeout=3)
        assert location() != saved, 'immediate quit flushes pending final movement'
        saved=location()
        assert process.returncode==0 and '\x1b[?1006l' in output, 'exit restores mouse handling'
    finally:
        if process.poll() is None: process.terminate(); process.wait(timeout=3)
        os.close(master)
    master, process = start()
    try:
        assert '? 帮助' in read(master) and pathlib.Path(directory,'view-mode').read_text()=='scroll', 'saved mode'
        key(master,b'q'); process.wait(timeout=3)
        restored=location()
        assert restored['chapter']==saved['chapter'] and abs(restored['offset']-saved['offset'])<80, 'resume content anchor'
    finally:
        if process.poll() is None: process.terminate(); process.wait(timeout=3)
        os.close(master)
print('PASS: terminal default scroll, line/reverse/wheel/screen movement, mode persistence, resize, resume and cleanup')
