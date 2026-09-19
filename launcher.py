# -*- coding: utf-8 -*-
"""
微软壁纸助手 - 绿色单文件版启动器。

设计要点
--------
* 本 exe 是 **GUI 子系统**（PyInstaller --windowed）。所以:
    - 双击           -> 自己 AllocConsole() 开一个控制台, 显示菜单。
                        没有"先建控制台再隐藏"的闪窗问题。
    - 开机后台自启    -> 完全不创建控制台, 一个窗口都不会闪。

* 绿色: 所有东西都在 exe 同级的「微软壁纸助手数据」目录里。
  删掉这个文件夹 = 彻底卸载, 不写注册表、不装计划任务、不需要管理员。

* 首次运行会把内嵌的 core.ps1 / menu.ps1 释放到数据目录, 并记录版本号;
  换新版 exe 后会自动重新释放 (按版本号比对)。

命令行
------
  (无参数)     打开菜单
  --daemon     后台常驻, 按 config.json 的 cycle_minutes 自动换壁纸 (给"开机自启"用)
  --once       不常驻, 只跑一轮 (调试用)
  --stop       通知正在跑的 --daemon 退出
"""
import io
import json
import msvcrt
import os
import shutil
import subprocess
import sys
import time
import datetime
import ctypes

VERSION = '1.4.0'
APP_NAME = '微软壁纸助手'
DATA_DIR_NAME = '微软壁纸助手数据'
PAYLOAD_FILES = ['core.ps1', 'menu.ps1', '使用说明.txt', '微软壁纸助手.ico']
MUTEX_NAME = 'Local\\MSWallpaperAssistantDaemon'
CREATE_NO_WINDOW = 0x08000000
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

PS_EXE = os.path.join(
    os.environ.get('SystemRoot', r'C:\Windows'),
    r'System32\WindowsPowerShell\v1.0\powershell.exe')

K32 = ctypes.windll.kernel32


# ---------------------------------------------------------------- 路径
def here():
    """exe 所在目录 (源码直跑时是脚本目录)。"""
    if getattr(sys, 'frozen', False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def payload_src():
    base = getattr(sys, '_MEIPASS', None) or here()
    return os.path.join(base, 'payload')


def writable(d):
    try:
        os.makedirs(d, exist_ok=True)
        t = os.path.join(d, '.wtest_' + str(os.getpid()))
        with open(t, 'w') as f:
            f.write('x')
        os.remove(t)
        return True
    except Exception:
        return False


def data_dir():
    """数据放哪, 按这个顺序找:
       1) exe 旁边已经有 config.json (老布局 / 便携用法) -> 就地接着用, 配置不搬家
       2) exe 旁边的「微软壁纸助手数据」子目录      -> 正常绿色布局
       3) exe 旁边写不进去 (Program Files 之类)      -> 退到 %LOCALAPPDATA%
    """
    h = here()
    if os.path.isfile(os.path.join(h, 'config.json')) and writable(h):
        return h
    d = os.path.join(h, DATA_DIR_NAME)
    if writable(d):
        return d
    fallback = os.path.join(os.environ.get('LOCALAPPDATA') or os.path.expanduser('~'), APP_NAME)
    os.makedirs(fallback, exist_ok=True)
    return fallback


# ---------------------------------------------------------------- 释放内嵌脚本
def sync_payload(d):
    src = payload_src()
    ver_file = os.path.join(d, '.version')
    cur = ''
    if os.path.isfile(ver_file):
        try:
            cur = open(ver_file, encoding='utf-8').read().strip()
        except Exception:
            cur = ''
    missing = [f for f in PAYLOAD_FILES if not os.path.isfile(os.path.join(d, f))]
    if cur == VERSION and not missing:
        return d, False

    if cur and cur != VERSION:
        # 版本变了: 清掉上一版释放过的脚本文件 (不碰 config/state/日志/壁纸)
        try:
            old = json.load(open(os.path.join(d, '.files.json'), encoding='utf-8'))
        except Exception:
            old = []
        for f in old:
            p = os.path.join(d, f)
            if os.path.isfile(p):
                try:
                    os.remove(p)
                except Exception:
                    pass

    for f in PAYLOAD_FILES:
        s = os.path.join(src, f)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(d, f))
    with open(ver_file, 'w', encoding='utf-8') as fp:
        fp.write(VERSION)
    with open(os.path.join(d, '.files.json'), 'w', encoding='utf-8') as fp:
        json.dump(PAYLOAD_FILES, fp)
    # 把 exe 的绝对路径留给菜单, 菜单靠它开/关"开机自动换"
    with open(os.path.join(d, 'launcher.txt'), 'w', encoding='utf-8') as fp:
        fp.write(os.path.abspath(sys.executable if getattr(sys, 'frozen', False) else __file__))
    return d, True


# ---------------------------------------------------------------- 控制台
def ensure_console():
    """GUI 子系统进程没有控制台。双击进来时自己开一个, 当菜单用。"""
    if K32.GetConsoleWindow():
        return True
    if not K32.AllocConsole():
        if not K32.AttachConsole(0xFFFFFFFF):   # 从 cmd 之类已有控制台的父进程启动
            return False
    try:
        K32.SetConsoleOutputCP(936)
        K32.SetConsoleCP(936)
        K32.SetConsoleTitleW('{} v{}'.format(APP_NAME, VERSION))
    except Exception:
        pass
    rw, open_existing = 0xC0000000, 3
    h_in = K32.CreateFileW('CONIN$', rw, 3, None, open_existing, 0, None)
    h_out = K32.CreateFileW('CONOUT$', rw, 3, None, open_existing, 0, None)
    if h_in in (None, INVALID_HANDLE_VALUE) or h_out in (None, INVALID_HANDLE_VALUE):
        return False
    K32.SetStdHandle(-10, h_in)
    K32.SetStdHandle(-11, h_out)
    K32.SetStdHandle(-12, h_out)
    try:
        fd_in = msvcrt.open_osfhandle(h_in, os.O_RDONLY)
        fd_out = msvcrt.open_osfhandle(h_out, os.O_WRONLY)
        sys.stdin = io.open(fd_in, 'r', encoding='cp936', errors='replace', buffering=1)
        sys.stdout = io.open(fd_out, 'w', encoding='cp936', errors='replace', buffering=1)
        sys.stderr = sys.stdout
    except Exception:
        pass
    return True


def say(msg):
    try:
        print(msg)
        sys.stdout.flush()
    except Exception:
        pass


# ---------------------------------------------------------------- 跑 PowerShell
def ps(script, args=(), no_window=True, wait=True):
    cmd = [PS_EXE, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script]
    cmd.extend(args)
    flags = CREATE_NO_WINDOW if no_window else 0
    if wait:
        return subprocess.run(cmd, creationflags=flags).returncode
    return subprocess.Popen(cmd, creationflags=flags)


def run_cycle(d):
    return ps(os.path.join(d, 'core.ps1'), ['-Cycle'], no_window=True)


def read_interval(d):
    try:
        with open(os.path.join(d, 'config.json'), encoding='utf-8-sig') as f:
            n = int(json.load(f).get('cycle_minutes') or 30)
        return n if n > 0 else 30
    except Exception:
        return 30


def read_last_swap(d):
    """上次真正换图的时刻, 读不到返回 None。

    这是节拍的唯一依据: 菜单上「下次自动换」显示的就是 last_swap + 间隔,
    core.ps1 判断该不该换也用它。daemon 必须跟着同一个数走, 否则
    显示的时刻到了却不换 (最多错一整轮)。
    """
    try:
        with open(os.path.join(d, 'state.json'), encoding='utf-8-sig') as f:
            v = (json.load(f).get('last_swap') or '').strip()
        if not v:
            return None
        return datetime.datetime.strptime(v, '%Y-%m-%d %H:%M:%S')
    except Exception:
        return None


# ---------------------------------------------------------------- 各模式
def mode_menu(d):
    if not ensure_console():
        return 1
    return ps(os.path.join(d, 'menu.ps1'), (), no_window=False)


def mode_daemon(d):
    # 单实例: 已经有一个在跑就安静退出
    K32.CreateMutexW(None, False, MUTEX_NAME)
    if K32.GetLastError() == 183:      # ERROR_ALREADY_EXISTS
        return 0
    stop_file = os.path.join(d, 'daemon.stop')
    if os.path.isfile(stop_file):
        try:
            os.remove(stop_file)
        except Exception:
            pass

    # 节拍跟着「上次换图时刻」走, 不跟着本进程的启动时刻走。
    # 老写法是"跑一轮 -> 睡满 30 分钟 -> 再跑一轮", 于是:
    #   手动换一张 -> last_swap 前移 -> 菜单显示的下次时间前移,
    #   但 daemon 还在按老节拍睡, 醒来一算没到点就又睡一整轮,
    #   表现就是"菜单说的时间到了却不换"。
    CHECK_S = 30    # 多久看一眼 state.json: 感知手动换图 / 停止信号
    LEAD_S = 2      # 到点后多等 2 秒, 避开 core.ps1 那边"差一点点没到"的边界

    prev = read_last_swap(d)
    hold_until = 0.0     # 这轮没换成图时的兜底: 至少等到这个时刻, 免得空转
    while True:
        if os.path.isfile(stop_file):
            try:
                os.remove(stop_file)
            except Exception:
                pass
            return 0

        gap = read_interval(d)
        ls = read_last_swap(d)
        if ls is not None and (prev is None or ls != prev):
            # 换过图了 (自己换的、菜单里手动换的、重启换的都算) -> 从这一刻重新计时
            hold_until = 0.0
            prev = ls
        target = 0.0 if ls is None else max(ls.timestamp() + gap * 60, hold_until)

        # 分片睡到目标时刻; 中途每 CHECK_S 秒醒一次看有没有变化
        due = False
        while True:
            left = target + LEAD_S - time.time()
            if left <= 0:
                due = True
                break
            time.sleep(min(CHECK_S, left))
            if os.path.isfile(stop_file):
                try:
                    os.remove(stop_file)
                except Exception:
                    pass
                return 0
            if read_last_swap(d) != prev:
                # 有人换过图了 (多半是用户在菜单里按了 [1]):
                # 这时候**不能**跟着换一张 —— 那会把人家刚挑的图顶掉。
                # 什么都不做, 回到外层按新的换图时刻重新算。
                break

        if not due:
            continue

        run_cycle(d)
        after = read_last_swap(d)
        if after is None or after == ls:
            # 这轮没换成 (网络不通 / 库是空的 / 必应还没发新图):
            # 不空转, 隔一整轮再试
            hold_until = time.time() + gap * 60
        prev = after


def mode_once(d):
    return run_cycle(d)


def mode_stop(d):
    try:
        with open(os.path.join(d, 'daemon.stop'), 'w', encoding='ascii') as f:
            f.write('stop')
    except Exception:
        pass
    return 0


def main():
    args = set(a.lower().lstrip('-').lstrip('/') for a in sys.argv[1:])
    d, _ = sync_payload(data_dir())
    if args & {'daemon', 'd'}:
        return mode_daemon(d)
    if args & {'stop', 'x'}:
        return mode_stop(d)
    if args & {'once', 'o'}:
        return mode_once(d)
    return mode_menu(d)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
