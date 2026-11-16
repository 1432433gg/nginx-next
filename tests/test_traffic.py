#!/usr/bin/env python3
"""隔离模拟网卡、时钟、启动标识、systemctl 和 nginx；不操作宿主服务。"""
import concurrent.futures
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
GUARD = REPO / "traffic/guard.sh"
INSTALL = REPO / "install.sh"
GB = 1_000_000_000

SYSTEMCTL = r'''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
p = pathlib.Path(os.environ['FAKE_CONTROL'])
with (p/'calls').open('a') as f: f.write(' '.join(sys.argv[1:])+'\n')
args=sys.argv[1:]
cmd=args[0]
if cmd=='is-active': sys.exit(0 if (p/'active').read_text()=='1' else 3)
if args[-1:] == ['nginx']:
    if cmd=='stop':
        if (p/'stop-fails').exists(): sys.exit(1)
        if (p/'pause-stop').exists():
            (p/'stop-entered').touch()
            deadline=time.monotonic()+5
            while not (p/'allow-stop').exists() and time.monotonic()<deadline: time.sleep(0.02)
            (p/'pause-stop').unlink()
        (p/'active').write_text('0')
    elif cmd in ('start','restart'):
        if (p/'start-fails').exists(): sys.exit(1)
        guard=os.environ['FAKE_START_GUARD']
        check=subprocess.run(['bash',guard,'check-start'],timeout=3)
        if check.returncode: sys.exit(check.returncode)
        (p/'active').write_text('1')
sys.exit(0)
'''

NGINX = r'''#!/usr/bin/env python3
import os, pathlib, sys
sys.exit(1 if (pathlib.Path(os.environ['FAKE_CONTROL'])/'bad-config').exists() else 0)
'''

DATE = r'''#!/usr/bin/env python3
import os, sys
if sys.argv[1:]==['+%Y-%m']:
    assert os.environ.get('TZ')=='Asia/Shanghai'
    if 'FAKE_MONTH_FILE' in os.environ:
        with open(os.environ['FAKE_MONTH_FILE']) as f: print(f.read().strip())
    else:
        print(os.environ['FAKE_MONTH'])
else:
    os.execv('/usr/bin/date',['date']+sys.argv[1:])
'''

WGET = r'''#!/usr/bin/env python3
import os, pathlib, shutil, sys
args=sys.argv[1:]
prefix='https://raw.githubusercontent.com/1432433gg/nginx-next/main/'
url=args[-1]
if not url.startswith(prefix) or '-O' not in args: sys.exit(1)
relative=url[len(prefix):]
source=pathlib.Path(os.environ['FAKE_RELEASE_ROOT'])/relative
if not source.is_file(): sys.exit(1)
destination=pathlib.Path(args[args.index('-O')+1])
shutil.copyfile(source,destination)
with open(os.environ['FAKE_DOWNLOAD_LOG'],'a') as f: f.write(relative+'\n')
'''


class TrafficTests(unittest.TestCase):
    def setUp(self):
        scratch = REPO / '.test-work'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name, body in [('systemctl', SYSTEMCTL), ('nginx', NGINX), ('date', DATE),
                           ('ip', '#!/usr/bin/env bash\nprintf "1.1.1.1 dev eth0 src 192.0.2.1\\n"\n')]:
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)
        self.net = self.root / 'net/eth0/statistics'
        self.net.mkdir(parents=True)
        self.tx(1000)
        self.boot_file = self.root / 'boot_id'
        self.boot(1)
        self.control = self.root / 'control'
        self.control.mkdir()
        (self.control / 'active').write_text('1')
        (self.control / 'calls').write_text('')
        self.state_dir = self.root / 'state'
        self.env = dict(os.environ, PATH=f'{self.bin}:'+os.environ['PATH'], TMPDIR=str(self.root),
                        NGINX_NEXT_TRAFFIC_DIR=str(self.state_dir),
                        NGINX_NEXT_SYS_NET=str(self.root / 'net'),
                        NGINX_NEXT_BOOT_ID_FILE=str(self.boot_file),
                        NGINX_NEXT_NGINX_BIN=str(self.bin / 'nginx'),
                        FAKE_CONTROL=str(self.control), FAKE_MONTH='2026-11',
                        FAKE_START_GUARD=str(GUARD))

    def tearDown(self):
        self.temp.cleanup()

    def tx(self, value):
        (self.net / 'tx_bytes').write_text(f'{value}\n')

    def boot(self, number):
        self.boot_file.write_text(f'00000000-0000-0000-0000-{number:012d}\n')

    def call(self, *args, ok=True):
        result = subprocess.run(['bash', str(GUARD), *map(str, args)], env=self.env,
                                text=True, capture_output=True, timeout=8)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def init(self, limit=GB, used=0):
        self.call('init', 'eth0', limit, used)

    def state(self):
        return dict(line.split('=', 1) for line in (self.state_dir/'state').read_text().splitlines())

    def used(self):
        return int(self.state()['used'])

    def active(self):
        return (self.control/'active').read_text() == '1'

    def shell(self, body, input='', ok=True, installed=False):
        guard = self.root/'installed/traffic-guard.sh' if installed else GUARD
        prefix = '''source "$1"
TRAFFIC_DIR=$NGINX_NEXT_TRAFFIC_DIR
TRAFFIC_GUARD=$2
SYSTEMD_DIR=$3
NGINX_BIN=$NGINX_NEXT_NGINX_BIN
'''
        result = subprocess.run(['bash', '-c', prefix+body, 'test', str(INSTALL),
                                 str(guard), str(self.root/'systemd')], input=input,
                                env=self.env, text=True, capture_output=True, timeout=12)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def run_script_upgrade(self, configured=False, over_quota=False, old_version='1.0.4'):
        client = self.root/'client'
        client.mkdir()
        rules = client/'rules'
        rules.mkdir()
        rule = rules/'10000.conf'
        original_rule = b'server {\n    listen 10000;\n    proxy_pass 1.2.3.4:443;\n}\n'
        rule.write_bytes(original_rule)
        if configured:
            self.init(limit=500*GB, used=(501 if over_quota else 123)*GB)
            self.shell('traffic_install_components', installed=True)
            (self.state_dir/'component-version').write_text('1.0.4\n')

        hook = '''
TRAFFIC_DIR=$NGINX_NEXT_TRAFFIC_DIR
TRAFFIC_GUARD=$FAKE_INSTALLED_GUARD
SYSTEMD_DIR=$FAKE_SYSTEMD_DIR
STREAM_DIR=$FAKE_STREAM_DIR
NGINX_BIN=$NGINX_NEXT_NGINX_BIN
is_root() { :; }
detect_system() { OS_ID=debian; }
nginx_listen_ports() { :; }
time_sync_state() { echo 已同步; }
congestion_state() { echo bbr; }
'''
        def isolated_source(text):
            self.assertIn('# 被 source 时', text)
            return text.replace('# 被 source 时', hook+'\n# 被 source 时', 1)

        release = self.root/'release'
        release.mkdir()
        for directory in ['nginx', 'chrony', 'apt', 'traffic', 'systemd']:
            shutil.copytree(REPO/directory, release/directory)
        (release/'install.sh').write_text(isolated_source(INSTALL.read_text()))

        old_script_env = 'NGINX_NEXT_TEST_OLD_SCRIPT_103' if old_version == '1.0.3' else 'NGINX_NEXT_TEST_OLD_SCRIPT'
        old_source = Path(os.environ.get(old_script_env, str(INSTALL))).read_text()
        old_source = re.sub(r'^SCRIPT_VERSION="[^"]+"$', f'SCRIPT_VERSION="{old_version}"', old_source, flags=re.M)
        old_script = client/'install.sh'
        old_script.write_text(isolated_source(old_source))
        old_script.chmod(0o755)
        wget = self.bin/'wget'
        wget.write_text(WGET)
        wget.chmod(0o755)
        download_log = self.root/'downloads'
        env = dict(self.env, FAKE_RELEASE_ROOT=str(release), FAKE_DOWNLOAD_LOG=str(download_log),
                   FAKE_INSTALLED_GUARD=str(self.root/'installed/traffic-guard.sh'),
                   FAKE_SYSTEMD_DIR=str(self.root/'systemd'), FAKE_STREAM_DIR=str(rules))
        result = subprocess.run(['bash', str(old_script)], input='2\n7\n', env=env,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr+'\n'+result.stdout)
        self.assertIn(f'已从 {old_version} 升级到 1.0.5', result.stdout)
        self.assertEqual(result.stdout.count('Nginx 端口转发一键脚本'), 2)
        self.assertIn('SCRIPT_VERSION="1.0.5"', old_script.read_text())
        self.assertEqual(rule.read_bytes(), original_rule)
        downloads = download_log.read_text().splitlines()
        self.assertEqual(downloads[0], 'install.sh')
        if configured:
            self.assertEqual(self.state()['limit'], str(500*GB))
            self.assertEqual(self.used(), (501 if over_quota else 123)*GB)
            self.assertEqual((self.state_dir/'component-version').read_text().strip(), '1.0.5')
            self.assertEqual((self.root/'installed/traffic-guard.sh').read_bytes(), GUARD.read_bytes())
            self.assertIn('traffic/guard.sh', downloads)
            self.assertIn('systemd/nginx-next-traffic-monthly.timer', downloads)
        else:
            self.assertFalse(self.state_dir.exists())
            self.assertEqual(downloads, ['install.sh'])
        return result

    def test_upgrade_from_104_preserves_traffic_settings_and_rules(self):
        result = self.run_script_upgrade(configured=True)
        self.assertTrue(self.active())
        self.assertIn('流量统计：已用 123.00 GB  上限 500.00 GB  剩余 377.00 GB', result.stdout)
        calls = (self.control/'calls').read_text().splitlines()
        self.assertNotIn('stop nginx', calls)
        self.assertNotIn('restart nginx', calls)

    def test_upgrade_from_104_does_not_restart_over_quota_nginx(self):
        result = self.run_script_upgrade(configured=True, over_quota=True)
        self.assertFalse(self.active())
        self.assertEqual(self.state()['blocked'], '1')
        self.assertIn('流量统计：已用 501.00 GB  上限 500.00 GB  剩余 0.00 GB', result.stdout)
        self.assertNotIn('start nginx', (self.control/'calls').read_text().splitlines())

    def test_upgrade_from_104_without_traffic_setup_does_not_prompt_or_initialize(self):
        result = self.run_script_upgrade()
        self.assertIn('流量统计：未设置', result.stdout)
        self.assertNotIn('流量上限（GB）', result.stdout)
        self.assertTrue(self.active())

    def test_upgrade_from_103_preserves_rules_and_supports_new_status_page(self):
        result = self.run_script_upgrade(old_version='1.0.3')
        self.assertIn('流量统计：未设置', result.stdout)
        self.assertTrue(self.active())

    def test_missing_traffic_dependencies_are_installed(self):
        result = self.shell('''
command() {
  if [[ $1 == -v && ( $2 == ip || $2 == flock ) ]]; then return 1; fi
  builtin command "$@"
}
apt_update() { echo APT_UPDATE; }
apt_install() { printf 'APT_INSTALL:%s\n' "$*"; }
traffic_ensure_deps
''')
        self.assertIn('APT_UPDATE', result.stdout)
        self.assertIn('APT_INSTALL:iproute2 util-linux', result.stdout)

    def test_existing_traffic_dependencies_do_not_trigger_package_install(self):
        result = self.shell('''
apt_update() { echo UNEXPECTED_APT; return 1; }
traffic_ensure_deps
''')
        self.assertEqual(result.stdout, '')

    def test_initial_counter_is_baseline_and_imported_usage_is_kept(self):
        self.init(used=700)
        self.tx(1250)
        self.call('tick')
        self.assertEqual(self.used(), 950)
        self.assertTrue(self.active())

    def test_exact_limit_stops_and_start_hook_rejects(self):
        self.init(used=GB-10)
        self.tx(1010)
        self.call('tick')
        self.assertFalse(self.active())
        self.assertEqual(self.state()['blocked'], '1')
        self.call('check-start', ok=False)
        result = subprocess.run(['systemctl', 'start', 'nginx'], env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.active())

    def test_overshoot_and_restart_of_monitor_do_not_reset_usage(self):
        self.init(used=GB-1)
        self.tx(1100)
        self.call('tick')
        self.call('tick')
        self.assertEqual(self.used(), GB+99)
        (self.control/'active').write_text('1')
        self.call('tick')
        self.assertFalse(self.active())

    def test_reboot_keeps_usage_and_counts_new_boot_bytes(self):
        self.init(used=500)
        self.boot(2)
        self.tx(70)
        self.call('tick')
        self.assertEqual(self.used(), 570)
        self.tx(90)
        self.call('tick')
        self.assertEqual(self.used(), 590)

    def test_interface_counter_reset_never_subtracts_usage(self):
        self.init(used=100)
        self.tx(20)
        self.call('tick')
        self.assertEqual(self.used(), 120)

    def test_new_month_resets_once_and_resumes_quota_stop(self):
        self.init(used=GB)
        self.call('tick')
        self.env['FAKE_MONTH'] = '2026-12'
        self.tx(2000)
        self.call('tick')
        self.assertEqual(self.used(), 0)
        self.assertTrue(self.active())
        self.assertEqual(self.state()['limit'], str(GB))
        self.tx(2200)
        self.call('tick')
        self.call('tick')
        self.assertEqual(self.used(), 200)
        self.assertEqual(self.state()['resume'], '0')

    def test_monthly_catch_up_after_offline_months(self):
        self.init(used=GB)
        self.call('tick')
        self.env['FAKE_MONTH'] = '2027-02'
        self.boot(2)
        self.tx(50)
        self.call('tick')
        self.assertEqual(self.state()['month'], '2027-02')
        self.assertEqual(self.used(), 0)
        self.assertTrue(self.active())

    def test_clock_rollback_does_not_reset_twice(self):
        self.init(used=500)
        self.env['FAKE_MONTH'] = '2026-10'
        self.tx(1100)
        self.call('tick')
        self.env['FAKE_MONTH'] = '2026-11'
        self.tx(1200)
        self.call('tick')
        self.assertEqual(self.used(), 700)

    def test_manual_reset_resumes_quota_stop_and_sets_new_baseline(self):
        self.init(used=GB)
        self.call('tick')
        self.tx(1500)
        self.call('reset')
        self.assertEqual(self.used(), 0)
        self.assertTrue(self.active())
        self.tx(1510)
        self.call('tick')
        self.assertEqual(self.used(), 10)

    def test_manual_stop_is_not_restarted_without_quota_recovery(self):
        self.init(used=50)
        (self.control/'active').write_text('0')
        self.call('reset')
        self.env['FAKE_MONTH'] = '2026-12'
        self.call('tick')
        self.assertFalse(self.active())

    def test_limit_changes_apply_immediately_and_persist_across_months(self):
        self.init(limit=200*GB, used=150*GB)
        self.call('set-limit', 100*GB)
        self.assertFalse(self.active())
        self.call('set-limit', 500*GB)
        self.assertTrue(self.active())
        self.env['FAKE_MONTH'] = '2026-12'
        self.call('tick')
        self.assertEqual(self.state()['limit'], str(500*GB))

    def test_setting_usage_replaces_instead_of_adding(self):
        self.init(used=100)
        self.call('set-used', 200)
        self.assertEqual(self.used(), 200)
        self.call('set-used', GB)
        self.assertFalse(self.active())
        self.call('set-used', 0)
        self.assertTrue(self.active())
        self.assertEqual(self.used(), 0)

    def test_invalid_cli_values_and_duplicate_initialization_keep_state(self):
        self.init(used=100)
        previous = (self.state_dir/'state').read_bytes()
        for command, value in [('set-limit','0'), ('set-limit','-1'), ('set-used','abc'),
                               ('set-used','01'), ('set-used','9999999999999999999')]:
            self.call(command, value, ok=False)
            self.assertEqual((self.state_dir/'state').read_bytes(), previous)
        self.call('init', 'eth0', GB, 0, ok=False)
        self.assertEqual((self.state_dir/'state').read_bytes(), previous)

    def test_corrupt_state_stops_without_executing_or_overwriting_it(self):
        self.init()
        state = self.state_dir/'state'
        bad = state.read_text()+'unexpected=$(touch NEVER_EXECUTE)\n'
        state.write_text(bad)
        self.call('tick', ok=False)
        self.assertFalse(self.active())
        self.assertEqual(state.read_text(), bad)
        self.call('check-start', ok=False)

    def test_missing_state_fails_closed_without_reinitializing(self):
        self.init()
        (self.state_dir/'state').unlink()
        self.call('tick', ok=False)
        self.assertFalse(self.active())
        self.assertFalse((self.state_dir/'state').exists())

    def test_unavailable_counter_is_not_treated_as_zero(self):
        self.init(used=100)
        (self.net/'tx_bytes').unlink()
        self.call('tick', ok=False)
        self.assertFalse(self.active())
        self.assertEqual(self.used(), 100)
        self.tx(1200)
        self.call('tick')
        self.assertEqual(self.used(), 300)

    def test_failed_monthly_resume_retries_after_config_is_fixed(self):
        self.init(used=GB)
        self.call('tick')
        (self.control/'bad-config').touch()
        self.env['FAKE_MONTH'] = '2026-12'
        self.call('tick', ok=False)
        self.assertEqual(self.used(), 0)
        self.assertEqual(self.state()['resume'], '1')
        self.assertFalse(self.active())
        (self.control/'bad-config').unlink()
        self.call('tick')
        self.assertTrue(self.active())
        self.assertEqual(self.state()['resume'], '0')

    def test_failed_stop_retries(self):
        self.init(used=GB)
        (self.control/'stop-fails').touch()
        self.call('tick', ok=False)
        self.assertEqual(self.state()['blocked'], '1')
        (self.control/'stop-fails').unlink()
        self.call('tick')
        self.assertFalse(self.active())

    def test_parallel_samples_never_double_count(self):
        self.init()
        self.tx(1600)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: self.call('tick'), range(20)))
        self.assertEqual(self.used(), 600)
        self.assertEqual(len(self.state()), 9)
        self.assertEqual((self.state_dir/'state').stat().st_mode & 0o777, 0o600)

    def test_reset_cannot_be_overtaken_by_an_old_stop_action(self):
        self.init(used=GB)
        (self.control/'pause-stop').touch()
        stopping = subprocess.Popen(['bash', str(GUARD), 'tick'], env=self.env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        resetting = None
        try:
            deadline = time.monotonic()+3
            while not (self.control/'stop-entered').exists() and time.monotonic()<deadline:
                time.sleep(0.02)
            self.assertTrue((self.control/'stop-entered').exists())
            resetting = subprocess.Popen(['bash', str(GUARD), 'reset'], env=self.env,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.15)
            self.assertEqual(self.used(), GB)
            (self.control/'allow-stop').touch()
            self.assertEqual(stopping.wait(timeout=5), 0)
            self.assertEqual(resetting.wait(timeout=5), 0)
            self.assertTrue(self.active())
            self.assertEqual(self.used(), 0)
        finally:
            (self.control/'allow-stop').touch()
            for proc in [stopping, resetting]:
                if proc is not None and proc.poll() is None:
                    proc.kill()
                    proc.wait()

    def test_input_defaults_zero_and_blank_limit_to_one_gb(self):
        for value in ['', '0', '0.000000000']:
            result = self.shell('read_traffic_value 流量上限 limit; printf "%s" "$TRAFFIC_INPUT_BYTES"', value+'\n')
            self.assertEqual(result.stdout, str(GB))
        result = self.shell('read_traffic_value 已用流量 used; printf "%s" "$TRAFFIC_INPUT_BYTES"', '\n')
        self.assertEqual(result.stdout, '0')

    def test_decimal_inputs_are_converted_to_integer_bytes(self):
        for value, expected in [('500',500*GB), ('001.25',1250000000), ('0.000000001',1),
                                ('999999.999999999',999999999999999)]:
            result = self.shell('read_traffic_value 已用流量 used; printf "%s" "$TRAFFIC_INPUT_BYTES"', value+'\n')
            self.assertEqual(result.stdout, str(expected))

    def test_invalid_input_reprompts_and_eof_returns(self):
        result = self.shell('read_traffic_value 流量上限 limit; printf "VALUE=%s" "$TRAFFIC_INPUT_BYTES"',
                            '-1\nabc\n1; echo BAD\n1.1234567890\n500\n')
        self.assertEqual(result.stdout.count('请输入有效数值'), 4)
        self.assertIn('VALUE=500000000000', result.stdout)
        self.shell('read_traffic_value 流量上限 limit', '', ok=False)

    def test_statistics_page_is_simple_and_remaining_clamped(self):
        self.init(limit=500*GB, used=63_200_000_000)
        result = self.shell('traffic_show')
        for text in ['已用流量：63.20 GB','流量上限：500.00 GB','剩余流量：436.80 GB',
                     'Nginx状态：运行中','1.  重置流量','2.  设置流量上限','3.  设置已用流量']:
            self.assertIn(text, result.stdout)
        for text in ['网卡','方向','月初','月份','默认']:
            self.assertNotIn(text, result.stdout)
        self.call('set-used', 501*GB)
        result = self.shell('traffic_show')
        self.assertIn('剩余流量：0.00 GB', result.stdout)
        self.assertIn('已停止（本月额度用尽）', result.stdout)

    def test_main_menu_order_and_dispatch(self):
        body = '''
is_root() { :; }
detect_system() { OS_ID=debian; }
traffic_update_components() { :; }
install_nginx() { echo ACTION_INSTALL; }
update_script() { echo ACTION_SCRIPT; }
add_rule() { echo ACTION_ADD; }
del_rule() { echo ACTION_DELETE; }
show_rules() { echo ACTION_RULES; }
traffic_menu() { echo ACTION_TRAFFIC; }
show_status() { echo ACTION_STATUS; }
update_nginx() { echo ACTION_UPDATE; }
update_kernel() { echo ACTION_KERNEL; }
install_bbr() { echo ACTION_BBR; }
menu
echo SHELL_RETURNED
'''
        expected = ['INSTALL', 'SCRIPT', 'ADD', 'DELETE', 'RULES', 'TRAFFIC',
                    'STATUS', 'UPDATE', 'KERNEL', 'BBR']
        for choice, action in enumerate(expected, 1):
            with self.subTest(choice=choice):
                result = self.shell(body, f'{choice}\n7\n')
                for text in ['6.','流量统计','7.','查看服务运行状态','8.','更新 Nginx','9.','更新 Linux 内核','10.']:
                    self.assertIn(text, result.stdout)
                actions = [line for line in result.stdout.splitlines() if line.startswith('ACTION_')]
                self.assertEqual(actions, ['ACTION_'+action])
                self.assertEqual(result.stdout.count('Nginx 端口转发一键脚本'), 1)
                self.assertTrue(result.stdout.rstrip().endswith('SHELL_RETURNED'))

    def test_service_status_displays_traffic_after_time_sync_and_exits(self):
        self.init(limit=500*GB, used=63_200_000_000)
        result = self.shell('''
is_root() { :; }
detect_system() { OS_ID=debian; }
traffic_update_components() { :; }
service_state() { echo 运行中; }
nginx_version() { echo 1.30.5; }
rule_ports() { echo 10000; }
nginx_listen_ports() { echo 10000; }
time_sync_state() { echo 已同步; }
congestion_state() { echo bbr; }
show_rules() { echo SECOND_ACTION_SHOULD_NOT_RUN; }
menu
echo SHELL_RETURNED
''', '7\n5\n')
        lines = result.stdout.splitlines()
        time_index = lines.index('时间同步：运行中  已同步')
        self.assertEqual(lines[time_index+1], '流量统计：已用 63.20 GB  上限 500.00 GB  剩余 436.80 GB')
        self.assertTrue(lines[time_index+2].startswith('当前时间：'))
        self.assertEqual(result.stdout.count('Nginx 端口转发一键脚本'), 1)
        self.assertNotIn('SECOND_ACTION_SHOULD_NOT_RUN', result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith('SHELL_RETURNED'))

    def test_service_status_does_not_initialize_unconfigured_traffic(self):
        result = self.shell('''
service_state() { echo 运行中; }
nginx_version() { echo 1.30.5; }
rule_ports() { :; }
nginx_listen_ports() { :; }
time_sync_state() { echo 已同步; }
congestion_state() { echo bbr; }
show_status
''', installed=True)
        self.assertIn('流量统计：未设置', result.stdout)
        self.assertNotIn('流量上限（GB）', result.stdout)
        self.assertFalse(self.state_dir.exists())
        self.assertEqual((self.control/'calls').read_text(), '')

    def test_service_status_samples_quota_before_reporting_nginx_state(self):
        self.init(limit=500*GB, used=501*GB)
        result = self.shell('''
service_state() {
  if systemctl is-active --quiet "$1"; then echo 运行中; else echo 未运行; fi
}
nginx_version() { echo 1.30.5; }
rule_ports() { :; }
nginx_listen_ports() {
  if systemctl is-active --quiet nginx; then echo 10000; fi
}
time_sync_state() { echo 已同步; }
congestion_state() { echo bbr; }
show_status
''')
        self.assertIn('Nginx：未运行  1.30.5', result.stdout)
        self.assertIn('监听端口：无', result.stdout)
        self.assertIn('流量统计：已用 501.00 GB  上限 500.00 GB  剩余 0.00 GB', result.stdout)
        self.assertFalse(self.active())

    def test_show_rules_returns_to_shell_without_reading_another_choice(self):
        result = self.shell('''
is_root() { :; }
detect_system() { OS_ID=debian; }
traffic_update_components() { :; }
show_status() { echo SECOND_ACTION_SHOULD_NOT_RUN; }
STREAM_DIR=$TRAFFIC_DIR/rules
mkdir -p "$STREAM_DIR"
printf 'server {\n    proxy_pass 1.2.3.4:443;\n}\n' >"$STREAM_DIR/10000.conf"
menu
echo SHELL_RETURNED
''', '5\n7\n')
        self.assertIn('1.2.3.4:443', result.stdout)
        self.assertEqual(result.stdout.count('Nginx 端口转发一键脚本'), 1)
        self.assertNotIn('SECOND_ACTION_SHOULD_NOT_RUN', result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith('SHELL_RETURNED'))

    def test_traffic_exit_returns_to_shell_without_reprinting_main_menu(self):
        self.init(limit=500*GB, used=0)
        result = self.shell('''
is_root() { :; }
detect_system() { OS_ID=debian; }
traffic_update_components() { :; }
require_installed() { :; }
show_status() { echo SECOND_ACTION_SHOULD_NOT_RUN; }
menu
echo SHELL_RETURNED
''', '6\n0\n7\n')
        self.assertEqual(result.stdout.count('Nginx 端口转发一键脚本'), 1)
        self.assertEqual(result.stdout.count('—————— 流量统计 ——————'), 1)
        self.assertNotIn('返回主菜单', result.stdout)
        self.assertNotIn('SECOND_ACTION_SHOULD_NOT_RUN', result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith('SHELL_RETURNED'))
        self.assertTrue(self.active())

    def test_reload_respects_quota_and_does_not_restart_nginx(self):
        self.init(used=GB)
        result = self.shell('reload_nginx; printf "PAUSED=%s" "$NGINX_QUOTA_PAUSED"')
        self.assertIn('PAUSED=1', result.stdout)
        calls = (self.control/'calls').read_text()
        self.assertNotIn('reload nginx', calls)
        self.assertNotIn('restart nginx', calls)
        self.assertFalse(self.active())

    def test_add_rule_is_saved_while_quota_paused(self):
        result = self.shell('''
STREAM_DIR=$TRAFFIC_DIR/rules
mkdir -p "$STREAM_DIR"
require_installed() { :; }
prepare_templates() { :; }
read_local_port() { LOCAL_PORT=12345; }
read_target() { TARGET=1.2.3.4; TARGET_IS_DOMAIN=0; }
read_target_port() { TARGET_PORT=443; }
render_template() { printf 'rule\n' >"$2"; }
check_nginx_config() { :; }
reload_nginx() { NGINX_QUOTA_PAUSED=1; }
nginx_listen_ports() { echo SHOULD_NOT_CHECK_LISTEN; return 1; }
add_rule
''')
        self.assertIn('已保存转发', result.stdout)
        self.assertTrue((self.state_dir/'rules/12345.conf').exists())

    def test_first_setup_and_options_two_three_one(self):
        result = self.shell('''
require_installed() { :; }
traffic_interface() { TRAFFIC_INTERFACE=eth0; }
traffic_menu
''', '500\n0\n2\n1000\n3\n150\n1\n0\n', installed=True)
        self.assertEqual(self.state()['limit'], str(1000*GB))
        self.assertEqual(self.used(), 0)
        self.assertIn('流量上限：1000.00 GB', result.stdout)
        self.assertIn('已用流量：150.00 GB', result.stdout)
        self.assertTrue((self.root/'systemd/nginx.service.d/traffic.conf').exists())
        self.assertTrue((self.root/'installed/traffic-guard.sh').stat().st_mode & 0o111)
        self.assertEqual((self.state_dir/'component-version').read_text().strip(), '1.0.5')

    def test_first_setup_zero_limit_means_one_gb(self):
        self.shell('''
require_installed() { :; }
traffic_interface() { TRAFFIC_INTERFACE=eth0; }
traffic_menu
''', '0\n0\n0\n', installed=True)
        self.assertEqual(self.state()['limit'], str(GB))

    def test_component_upgrade_does_not_reset_ledger(self):
        self.init(limit=500*GB, used=123*GB)
        self.shell('traffic_install_components', installed=True)
        self.assertEqual(self.used(), 123*GB)
        self.assertEqual(self.state()['limit'], str(500*GB))
        rendered = (self.root/'systemd/nginx-next-traffic-monthly.timer').read_text()
        self.assertIn('OnCalendar=*-*-01 00:00:00 Asia/Shanghai', rendered)
        self.assertIn('Persistent=true', rendered)
        dropin = (self.root/'systemd/nginx.service.d/traffic.conf').read_text()
        self.assertIn('check-start', dropin)
        self.assertIn('ExecStop=\nKillSignal=SIGTERM', dropin)
        self.assertNotIn('{{', dropin)

    def test_flush_records_usage_without_starting_or_stopping_services(self):
        self.init(used=GB-10)
        self.tx(1100)
        self.call('flush')
        self.assertEqual(self.used(), GB+90)
        self.assertEqual((self.control/'calls').read_text(), '')
        (self.net/'tx_bytes').unlink()
        self.call('flush', ok=False)
        self.assertEqual((self.control/'calls').read_text(), '')

    def test_background_daemon_stops_then_resumes_at_month_change(self):
        self.init(used=GB-10)
        month_file = self.root/'month'
        month_file.write_text('2026-11')
        env = dict(self.env, FAKE_MONTH_FILE=str(month_file))
        daemon = subprocess.Popen(['bash', str(GUARD), 'daemon'], env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  start_new_session=True)
        def wait_for(predicate):
            deadline = time.monotonic()+13
            while time.monotonic()<deadline:
                if predicate(): return
                self.assertIsNone(daemon.poll(), '后台服务意外退出')
                time.sleep(0.05)
            self.fail('后台检查未按预期执行')
        try:
            self.tx(1020)
            wait_for(lambda: not self.active())
            self.assertGreaterEqual(self.used(), GB)
            month_file.write_text('2026-12')
            wait_for(self.active)
            self.assertEqual(self.used(), 0)
        finally:
            os.killpg(daemon.pid, signal.SIGTERM)
            daemon.wait(timeout=5)


if __name__ == '__main__':
    unittest.main(verbosity=2)
