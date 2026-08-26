#!/usr/bin/env python3
import argparse, json, os, platform, re, shutil, subprocess, sys, textwrap, time, shlex
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILDS = ROOT / 'builds'
DATA = ROOT / 'data'
DEPS = DATA / 'dependencies.json'


def run(cmd, timeout=15):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout.strip(), p.stderr.strip(), p.returncode
    except Exception as e:
        return '', str(e), 1


def read_file(path, limit=200000):
    try:
        return Path(path).read_text(errors='replace')[:limit]
    except Exception:
        return ''


def os_profile():
    info = {}
    for k, v in re.findall(r'^([A-Z_]+)=(.*)$', read_file('/etc/os-release'), re.M):
        info[k] = v.strip().strip('"')
    version = info.get('VERSION_ID', '')
    supported = info.get('ID') == 'ubuntu' and version in {'24.04', '26.04'}
    return {
        'id': info.get('ID', platform.system().lower()),
        'name': info.get('PRETTY_NAME', platform.platform()),
        'version_id': version,
        'codename': info.get('VERSION_CODENAME', ''),
        'supported_target': supported,
        'kernel': platform.release(),
        'arch': platform.machine(),
    }


def lshw_json():
    out, err, rc = run(['lshw', '-json', '-sanitize'], 30)
    if rc == 0 and out:
        try:
            return json.loads(out)
        except Exception:
            pass
    return {}


def flatten_lshw(node, out=None):
    out = out or []
    if isinstance(node, dict):
        out.append(node)
        for child in node.get('children', []) or []:
            flatten_lshw(child, out)
    elif isinstance(node, list):
        for x in node:
            flatten_lshw(x, out)
    return out


def pci_devices():
    out, _, rc = run(['lspci', '-nnk'], 15)
    return out if rc == 0 else ''


def commands_present(names):
    return {name: bool(shutil.which(name)) for name in names}


def load_dependencies():
    try:
        return json.loads(DEPS.read_text())
    except Exception:
        return {}


def dpkg_installed(pkg):
    out, _, rc = run(['dpkg-query', '-W', '-f=${Status}', pkg], 5)
    return rc == 0 and out.startswith('install ok installed')


def command_path(name):
    return shutil.which(name)


def which_version(name, allow_env_refresh=True):
    path = shutil.which(name)
    if not path and allow_env_refresh and name in {'icx','icpx','sycl-ls'}:
        env_info = discover_oneapi_environment()
        path = env_info.get('commands', {}).get(name)
        if path:
            out, err, rc = run([path, '--version'], 8)
            version = (out or err).splitlines()[0] if (out or err) else ''
            return {'path': path, 'version': version, 'environment': env_info.get('environment', {})}
    if not path:
        return None
    out, err, rc = run([path, '--version'], 8)
    version = (out or err).splitlines()[0] if (out or err) else ''
    return {'path': path, 'version': version}


def discover_oneapi_environment():
    candidates = [
        Path('/opt/intel/oneapi/setvars.sh'),
        Path('/opt/intel/oneapi/latest/setvars.sh'),
    ]
    setvars = next((x for x in candidates if x.is_file()), None)
    if not setvars:
        return {'available': False, 'commands': {}, 'environment': {}}
    cmd = [
        'bash','-lc',
        'source ' + shlex_quote(str(setvars)) + ' >/dev/null 2>&1; '
        'printf "PATH=%s\nLD_LIBRARY_PATH=%s\nCPATH=%s\nLIBRARY_PATH=%s\nONEAPI_ROOT=%s\n" "$PATH" "$LD_LIBRARY_PATH" "$CPATH" "$LIBRARY_PATH" "${ONEAPI_ROOT:-}"; '
        'command -v icx || true; command -v icpx || true; command -v sycl-ls || true'
    ]
    out, err, rc = run(cmd, 20)
    lines = (out or '').splitlines()
    env = {}
    commands = {}
    for line in lines[:5]:
        if '=' in line:
            k,v=line.split('=',1); env[k]=v
    for line in lines[5:]:
        base=Path(line.strip()).name if line.strip() else ''
        if base in {'icx','icpx','sycl-ls'}:
            commands[base]=line.strip()
    if commands:
        env['ONEAPI_SET_VARS'] = str(setvars)
    return {'available': bool(commands), 'commands': commands, 'environment': env}


def shlex_quote(v):
    import shlex
    return shlex.quote(str(v))


def rocm_environment():
    roots=[Path('/opt/rocm'), Path('/opt/rocm-7.1.1'), Path('/opt/rocm-7.1.0')]
    root=next((x for x in roots if x.is_dir()), None)
    if not root:
        return {'available': False, 'root': None, 'commands': {}}
    cmds={}
    for name in ['hipcc','rocminfo','hipconfig']:
        for candidate in [root/'bin'/name, root/'llvm'/bin if False else root/'bin'/name]:
            if candidate.is_file() and os.access(candidate, os.X_OK):
                cmds[name]=str(candidate); break
    # hipcc may be a symlink under the versioned ROCm tree. Resolve its target as well.
    if not cmds.get('hipcc') and shutil.which('hipcc'):
        cmds['hipcc']=shutil.which('hipcc')
    return {'available': bool(cmds.get('hipcc')), 'root': str(root), 'commands': cmds}


def find_llama_cpp(progress=None):
    """Find llama.cpp without recursively crawling large trees.

    Discovery is intentionally bounded. A previous implementation used Path.glob('**/llama.cpp')
    under $HOME and could consume CPU for a long time. We now inspect known roots to a small
    depth and stop after a modest directory budget.
    """
    found = []
    seen = set()
    source_candidates = []
    env = os.environ.get('LLAMA_CPP_SOURCE', '')
    if env:
        source_candidates.append(Path(env).expanduser())

    home = Path.home()
    roots = [
        home / 'llama.cpp', home / 'ai_stack' / 'llama.cpp', home / 'src' / 'llama.cpp',
        home / 'src' / 'llama', home / 'projects' / 'llama.cpp', home / 'workspace' / 'llama.cpp',
        home / 'Downloads' / 'llama.cpp', home / 'git' / 'llama.cpp',
        Path('/opt/llama.cpp'), Path('/usr/local/src/llama.cpp'), Path('/usr/src/llama.cpp'),
        Path('/workspace/llama.cpp'),
    ]
    roots.extend([home / x for x in ['llm', 'ai', 'ai_stack', 'src', 'projects', 'workspace', 'git', 'Downloads']])

    if progress:
        progress('llama.cpp source search', f'Checking {len(roots)} known roots (bounded depth, no full-disk crawl)')

    queue = []
    for root in roots:
        if root.is_dir():
            queue.append((root, 0))

    visited_dirs = 0
    max_dirs = 1500
    max_depth = 3
    ignored = {'.git', '.cache', '.cargo', '.npm', '.local', '.venv', 'node_modules', '__pycache__'}
    while queue and visited_dirs < max_dirs:
        base, depth = queue.pop(0)
        visited_dirs += 1
        try:
            if (base / 'CMakeLists.txt').is_file() and (base / 'ggml').is_dir():
                source_candidates.append(base)
                continue
            if depth >= max_depth:
                continue
            for child in base.iterdir():
                try:
                    if child.is_dir() and child.name not in ignored and not child.is_symlink():
                        queue.append((child, depth + 1))
                except OSError:
                    continue
        except OSError:
            continue

    # Also use common installed binaries. This is cheap and deterministic.
    for name in ['llama-cli', 'llama-server', 'llama-bench', 'llama-run']:
        info = which_version(name)
        if info:
            found.append({'type': 'binary', 'name': name, **info})

    for base in [home / 'llama.cpp' / 'build' / 'bin', home / 'ai_stack' / 'llama.cpp' / 'build' / 'bin', Path('/usr/local/bin')]:
        for name in ['llama-cli', 'llama-server', 'llama-bench', 'llama-run']:
            f = base / name
            if f.is_file() and os.access(f, os.X_OK):
                found.append({'type': 'binary', 'name': name, 'path': str(f)})

    for p in source_candidates:
        try:
            rp = p.resolve()
        except Exception:
            continue
        key = str(rp)
        if key in seen or not rp.is_dir():
            continue
        if (rp / 'CMakeLists.txt').is_file() and (rp / 'ggml').is_dir():
            seen.add(key)
            found.append({'type': 'source', 'path': key, 'git': (rp / '.git').exists()})

    if progress:
        progress('llama.cpp source search', f'Finished: {len([x for x in found if x.get("type") == "source"])} source tree(s), {visited_dirs} directories inspected')
    return found


_APT_CACHE = {}
def apt_cache_available(pkg):
    if pkg in _APT_CACHE:
        return _APT_CACHE[pkg]
    out, err, rc = run(['apt-cache', 'policy', pkg], 10)
    ok = rc == 0 and bool(re.search(r'Candidate:\s+(?!\(none\))\S+', out))
    _APT_CACHE[pkg] = ok
    return ok


def hardware_backend_needs(hw):
    """Return backends that can actually solve this machine, avoiding dead-end stacks."""
    needs=[]
    for g in hw.get('gpus', []):
        text=json.dumps(g).lower()
        discrete = g.get('form_factor') == 'discrete'
        if 'nvidia' in text:
            needs.append('cuda')
        elif 'intel' in text:
            needs.append('sycl')
        elif 'amd' in text or 'radeon' in text:
            # Do not force ROCm for integrated Radeon APUs. AMD's current guidance has
            # limitations around integrated graphics, so HIP is only a primary path here
            # for discrete AMD GPUs. Vulkan remains a safe alternate when available.
            if discrete:
                needs.append('rocm')
    # If Intel/AMD/NVIDIA hardware exists, Vulkan is a useful alternate accelerator path,
    # but it is not a hard requirement when a native vendor backend is available.
    return list(dict.fromkeys(needs))


def dependency_inventory(hw, progress=None):
    deps = load_dependencies()
    tools = dict(hw.get('tools', {}))
    oneapi = discover_oneapi_environment()
    roc = rocm_environment()
    if oneapi.get('available'):
        tools['icx'] = True; tools['icpx'] = True; tools['sycl-ls'] = True
    if roc.get('available'):
        tools['hipcc'] = True
    # Base checks must reflect installed APT packages as well as PATH. The previous
    # PATH-only check falsely reported 'base' missing on machines where gcc/cmake/etc.
    # were definitely installed.
    base_pkgs = ['build-essential','cmake','git','pkg-config','ninja-build']
    base_tools_ok = all(tools.get(x) for x in ['cmake','git','gcc','g++','pkg-config'])
    base_pkgs_ok = all(dpkg_installed(x) for x in base_pkgs)
    checks = {
        'base': base_tools_ok or base_pkgs_ok,
        'vulkan': all(tools.get(x) for x in ['vulkaninfo']) and Path('/usr/include/vulkan').exists(),
        'opencl': bool(tools.get('clinfo')),
        'cuda': bool(tools.get('nvcc')) and bool(tools.get('nvidia-smi')),
        'rocm': bool(tools.get('hipcc')) and (bool(tools.get('rocminfo')) or bool(dpkg_installed('rocminfo'))),
        'sycl': bool(tools.get('icpx')) and bool(tools.get('sycl-ls')),
    }
    checks['intel_driver'] = Path('/usr/lib/x86_64-linux-gnu/libze_loader.so').exists() or Path('/dev/dri').exists()
    checks['amd_driver'] = Path('/dev/kfd').exists() or bool(tools.get('rocminfo'))
    checks['nvidia_driver'] = bool(tools.get('nvidia-smi'))
    return {
        'llama_cpp': find_llama_cpp(progress),
        'checks': checks,
        'packages': deps.get('ubuntu', {}).get(hw['os']['version_id'], {}),
        'manual': deps.get('manual', {}),
        'oneapi': oneapi,
        'rocm': roc,
    }


def dependency_status(hw, progress=None):
    if progress:
        progress('Dependency inventory', 'Starting toolchain and runtime checks')
    inv = dependency_inventory(hw, progress)
    required = ['base'] + hardware_backend_needs(hw)
    # A backend only becomes required when it is a viable path for the actual accelerator.
    # OpenCL/Vulkan are optional fallbacks unless no native backend can solve the detected GPU.
    if not hardware_backend_needs(hw):
        caps = hw.get('capabilities', {})
        if caps.get('vulkan'):
            required.append('vulkan')
        elif caps.get('opencl'):
            required.append('opencl')
    required = list(dict.fromkeys(required))
    missing = [x for x in required if not inv['checks'].get(x)]
    return inv, missing, required


def progress_line(stage, message):
    print(f'[{stage}] {message}', flush=True)


def safe_input(prompt, default=''):
    try:
        return input(prompt)
    except KeyboardInterrupt:
        print('\nCancelled by user. Returning to the menu.')
        return default
    except EOFError:
        return default


def _apt_install(packages, label):
    packages=list(dict.fromkeys(packages))
    if not packages:
        return True
    progress_line('APT', 'Refreshing package metadata')
    rc = subprocess.run(['sudo','apt-get','update'], check=False).returncode
    if rc != 0:
        print(f'[APT] update returned exit {rc}. The requested install will still be attempted so its failure is visible.')
    progress_line('APT', f'Installing {len(packages)} package(s) for {label}: ' + ', '.join(packages))
    rc = subprocess.run(['sudo','apt-get','install','-y',*packages], check=False).returncode
    progress_line('APT', f'Install completed with exit {rc}')
    return rc == 0


def vendor_recipe(hw, group, inv):
    """Return a safe, actionable next step. Avoids unsupported cross-release repository mixing."""
    osid=hw['os']['version_id']
    if group == 'sycl':
        # Intel's official 2026.1 APT install uses this package and an all-main repo.
        return {
            'title':'Intel oneAPI DPC++/C++ compiler',
            'commands':[
                'sudo apt-get update',
                'sudo apt-get install -y intel-oneapi-compiler-dpcpp-cpp',
            ],
            'note':'The forge will then source /opt/intel/oneapi/setvars.sh and verify icx, icpx and sycl-ls before offering the SYCL build.'
        }
    if group == 'rocm':
        if osid == '24.04':
            return {
                'title':'AMD ROCm',
                'commands':[
                    'Download/register the AMD ROCm repository for Ubuntu 24.04 using AMD\'s current 7.1.x instructions.',
                    'sudo apt-get update',
                    'sudo apt-get install -y rocm',
                ],
                'note':'The official ROCm docs currently provide Ubuntu 24.04 package-manager instructions. After installation the forge will verify hipcc and rocminfo.'
            }
        return {
            'title':'AMD ROCm on Ubuntu 26.04',
            'commands':[],
            'note':'The current AMD ROCm native package documentation does not list Ubuntu 26.04 in the supported Ubuntu targets. Do not mix a 24.04/noble ROCm repository into 26.04/resolute. The forge will not perform that unsafe cross-release install.'
        }
    if group == 'cuda':
        return {
            'title':'NVIDIA CUDA Toolkit',
            'commands':['Install the CUDA toolkit from NVIDIA\'s repository for this exact Ubuntu release.'],
            'note':'The forge will re-scan for both nvcc and nvidia-smi before offering CUDA builds.'
        }
    return None


def install_missing_dependencies(hw):
    print('\n=== DEPENDENCY / TOOLCHAIN CHECK ===')
    print('Live, bounded discovery. Each missing item gets a concrete next action; the forge will not stop at “manual install”.')
    try:
        inv, missing, required = dependency_status(hw, progress=progress_line)
    except KeyboardInterrupt:
        print('\nDependency scan cancelled safely. No installation was attempted.')
        return

    print('\n--- llama.cpp ---')
    for x in inv['llama_cpp']:
        if x.get('type') == 'source': print(f"  SOURCE  {x['path']}" + ('  [git]' if x.get('git') else ''))
        else: print(f"  BINARY  {x.get('name')}  {x.get('path','')}  {x.get('version','')}")
    if not inv['llama_cpp']:
        print('  none found in the bounded search locations')

    print('\n--- prerequisites ---')
    for k,v in inv['checks'].items():
        if k in required:
            label='OK' if v else 'MISSING'
        else:
            label='OK' if v else 'not required'
        print(f'  {k:18} {label}')

    if not missing:
        print('\nRESULT: all required prerequisites are present.')
        if inv['oneapi'].get('available'):
            print('  Intel oneAPI environment discovered and can be loaded automatically for builds.')
        if inv['rocm'].get('available'):
            print(f"  ROCm root discovered at {inv['rocm'].get('root')}")
        return

    print('\nRESULT: missing required components: ' + ', '.join(missing))
    if hw['os']['id'] != 'ubuntu' or hw['os']['version_id'] not in {'24.04','26.04'}:
        print('Automatic installation is limited to Ubuntu 24.04/26.04.')
        return

    # Solve what can safely be solved from configured APT repos first.
    packages=[]
    for group in missing:
        for pkg in inv['packages'].get(group, []):
            if apt_cache_available(pkg): packages.append(pkg)
    packages=list(dict.fromkeys(packages))
    if packages:
        print('\n--- Safe APT actions available now ---')
        for x in packages: print('  + '+x)
        answer=safe_input('\nInstall these packages now? [y/N]: ').strip().lower()
        if answer=='y':
            _apt_install(packages,'base/runtime prerequisites')
            try:
                inv, missing, required = dependency_status(scan_hardware(), progress=progress_line)
            except KeyboardInterrupt:
                print('\nRe-scan cancelled safely.')
                return
        else:
            print('APT installation skipped.')

    # Handle vendor stacks as guided workflows, not dead ends.
    for group in list(missing):
        recipe=vendor_recipe(hw,group,inv)
        if not recipe: continue
        print(f"\n--- ACTION REQUIRED: {recipe['title']} ---")
        for command in recipe['commands']:
            print('  '+command)
        print('  '+recipe['note'])
        if recipe['commands'] and all(c.startswith('sudo apt') for c in recipe['commands']):
            answer=safe_input('Run the supported install step now? [y/N]: ').strip().lower()
            if answer=='y':
                _apt_install(['intel-oneapi-compiler-dpcpp-cpp'],'Intel oneAPI SYCL') if group=='sycl' else None
        elif not recipe['commands']:
            print('  No unsafe automatic repository installation was attempted.')

    # Final verification and explicit solution state.
    try:
        inv2, missing2, required2 = dependency_status(scan_hardware(), progress=progress_line)
    except KeyboardInterrupt:
        print('\nFinal verification cancelled.')
        return
    if not missing2:
        print('\nSOLUTION STATUS: READY TO GENERATE A BUILD.')
        return
    print('\nSOLUTION STATUS: BLOCKED')
    for group in missing2:
        recipe=vendor_recipe(hw,group,inv2)
        if recipe:
            print(f"  {group}: {recipe['title']} -> {recipe['note']}")
        else:
            print(f'  {group}: no automated resolver available yet')


def require_dependencies(hw, interactive=False):
    inv, missing, required = dependency_status(hw, progress=progress_line)
    if not missing: return True
    print('\nBUILD PREREQUISITES MISSING: ' + ', '.join(missing))
    print('[AUTO-RESOLVE] Starting the dependency resolver because a build was explicitly requested.')
    install_missing_dependencies(hw)
    inv, missing, required = dependency_status(scan_hardware(), progress=progress_line)
    if missing:
        print('Build blocked: unresolved prerequisites remain. No compilation was started.')
        return False
    print('[AUTO-RESOLVE] All required prerequisites are now present. Continuing to build.')
    return True

def scan_hardware():
    osh = os_profile()
    hw = lshw_json()
    flat = flatten_lshw(hw)
    pci = pci_devices()
    gpus, nics, cpus, npus, tpus = [], [], [], [], []
    for d in flat:
        cls = d.get('class', '')
        desc = str(d.get('description', ''))
        blob = json.dumps(d).lower()
        # Only count actual display/3D accelerator devices. PCI bridges, video buses,
        # root complexes and generic 'graphics' descriptions are not GPUs.
        if cls in {'display', '3d'}:
            gpus.append({k: d.get(k) for k in ['id','product','vendor','version','width','clock','size','configuration','businfo','physid']})
        if cls == 'processor':
            cpus.append({k: d.get(k) for k in ['id','product','vendor','version','width','clock']})
        if cls == 'network':
            nics.append({k: d.get(k) for k in ['id','product','vendor','logicalname','configuration']})
        if any(x in blob for x in ['neural processing unit', ' npu', 'npu ', 'neural accelerator']):
            npus.append({k: d.get(k) for k in ['id','product','vendor','version','configuration','businfo']})
        if any(x in blob for x in ['tensor processing unit', ' tpu', 'tpu ', 'coral']) or 'google edge tpu' in blob:
            tpus.append({k: d.get(k) for k in ['id','product','vendor','version','configuration','businfo']})

    # Deduplicate identical lshw entries by bus/product/vendor.
    uniq = {}
    for g in gpus:
        key = (g.get('businfo') or '', g.get('vendor') or '', g.get('product') or '')
        uniq.setdefault(key, g)
    gpus = list(uniq.values())
    for g in gpus:
        text=json.dumps(g).lower()
        integrated = any(x in text for x in ['radeon graphics','vega graphics','apu','uhd graphics','iris xe','iris graphics'])
        g['form_factor'] = 'integrated' if integrated else 'discrete'

    tools = commands_present([
        'cmake','ninja','gcc','g++','clang','clang++','icx','icpx','hipcc','nvcc',
        'vulkaninfo','clinfo','sycl-ls','xpu-smi','rocminfo','nvidia-smi','glxinfo',
        'ccache','sccache','git','lspci','lshw'
    ])
    oneapi = discover_oneapi_environment()
    roc = rocm_environment()
    if oneapi.get('available'):
        tools['icx'] = True; tools['icpx'] = True; tools['sycl-ls'] = True
    if roc.get('available'):
        tools['hipcc'] = True
    drivers = {
        'cuda': bool(tools.get('nvcc')) or bool(re.search(r'VGA compatible controller: NVIDIA|3D controller: NVIDIA', pci, re.I)),
        'amd': bool(re.search(r'VGA compatible controller: (Advanced Micro Devices|AMD)|3D controller: (Advanced Micro Devices|AMD)', pci, re.I)),
        'intel': bool(re.search(r'VGA compatible controller: Intel|3D controller: Intel', pci, re.I)) or bool(oneapi.get('available')),
        'vulkan': bool(tools.get('vulkaninfo')),
        'opencl': bool(tools.get('clinfo')),
        'sycl': bool(oneapi.get('available')) or (bool(tools.get('sycl-ls')) and bool(tools.get('icpx'))),
        'rocm': bool(roc.get('available')) or bool(tools.get('rocminfo')) or bool(tools.get('hipcc')),
        'npu': bool(npus) or Path('/dev/accel').exists(),
        'tpu': bool(tpus) or bool(re.search(r'Coral|Edge TPU|Tensor Processing Unit|TPU', pci, re.I)),
    }
    accelerator_present = bool(gpus or npus or tpus) or any(drivers.values())
    return {
        'timestamp': datetime.now(timezone.utc).isoformat(),
        'os': osh,
        'cpu': cpus,
        'gpus': gpus,
        'npus': npus,
        'tpus': tpus,
        'network': nics,
        'pci': pci,
        'tools': tools,
        'capabilities': drivers,
        'accelerator_present': accelerator_present,
    }


# Accessible terminal presentation. Set NO_COLOR=1 or LLAMA_FORGE_NO_COLOR=1 to disable ANSI colour.
_USE_COLOUR = sys.stdout.isatty() and not os.environ.get('NO_COLOR') and not os.environ.get('LLAMA_FORGE_NO_COLOR')
_COLOUR = {
    'reset':'\033[0m', 'bold':'\033[1m', 'cyan':'\033[96m', 'green':'\033[92m',
    'yellow':'\033[93m', 'red':'\033[91m', 'blue':'\033[94m', 'white':'\033[97m',
}

def paint(text, colour=None, *, bold=False):
    if not _USE_COLOUR:
        return str(text)
    parts=[]
    if bold: parts.append(_COLOUR['bold'])
    if colour in _COLOUR: parts.append(_COLOUR[colour])
    parts.append(str(text))
    parts.append(_COLOUR['reset'])
    return ''.join(parts)

def status_mark(status):
    return {'READY':'[OK]','BUILT':'[DONE]','BLOCKED':'[BLOCKED]','FAILED':'[FAILED]','OPTIONAL':'[OPTIONAL]','RECOMMENDED':'[RECOMMENDED]'}.get(str(status).upper(), '[INFO]')

def normalise_menu_choice(value):
    value = str(value).strip()
    if value.endswith('.'):
        value = value[:-1].strip()
    return value

def catalogue_description(item):
    """Return a meaningful, user-facing explanation for a CMake option."""
    return str(item.get('meaningful_description') or item.get('description') or 'No description is available yet. Refresh the catalogue against the current llama.cpp source.')

def load_catalogue():
    """Load and normalize the switch catalogue to a list of dict entries.

    Historical catalogue files used both a top-level list and a mapping with a
    `switches` list.  The guided editor should consume one stable shape and
    must never crash because a refresh returned a different container shape.
    """
    raw = json.loads((DATA / 'build_switches.json').read_text())
    if isinstance(raw, dict):
        raw = raw.get('switches', [])
    if not isinstance(raw, list):
        print('[catalogue] invalid switch catalogue shape; using empty catalogue', file=sys.stderr)
        return []
    normalized = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        key = item.get('key') or item.get('name')
        if not key:
            continue
        x = dict(item)
        x['key'] = key
        if 'examples' not in x and x.get('example'):
            x['examples'] = [x['example']]
        x['meaningful_description'] = catalogue_description(x)
        if isinstance(x.get('use_cases'), str):
            x['use_cases'] = [x['use_cases']]
        normalized.append(x)
    return normalized


def option_kind(item, key, value):
    typ = str(item.get('type','')).lower() if isinstance(item, dict) else ''
    if typ in {'bool','boolean'}:
        return 'bool'
    if typ in {'string','path','int','integer','number'}:
        return 'value'
    sval = str(value).upper()
    return 'bool' if sval in {'ON','OFF','TRUE','FALSE','0','1'} else 'value'


def option_state(item, key, value, recommended=False, protected=False):
    kind = option_kind(item, key, value)
    sval = str(value)
    if protected:
        mark = 'PROTECTED'
    elif recommended:
        mark = 'RECOMMENDED'
    elif kind == 'bool' and sval.upper() in {'ON','TRUE','1'}:
        mark = 'ENABLED'
    else:
        mark = 'OPTIONAL'
    return kind, mark


def selected_llama_source(hw=None):
    if hw:
        for item in hw.get('_llama_cpp', []):
            if item.get('type') == 'source':
                return item.get('path')
    found = find_llama_cpp()
    for item in found:
        if item.get('type') == 'source':
            return item.get('path')
    return ''


def profile_blockers(profile, hw):
    """Return concrete blockers for a profile without making up missing support."""
    cm = profile.get('cmake', {})
    caps = hw.get('capabilities', {})
    blockers = []
    if cm.get('GGML_SYCL') == 'ON' and not caps.get('sycl'):
        blockers.append('Intel SYCL / oneAPI is not ready')
    if cm.get('GGML_HIP') == 'ON' and not caps.get('rocm'):
        blockers.append('AMD ROCm/HIP is not ready')
    if cm.get('GGML_CUDA') == 'ON' and not caps.get('cuda'):
        blockers.append('NVIDIA CUDA is not ready')
    if cm.get('GGML_VULKAN') == 'ON' and not caps.get('vulkan'):
        blockers.append('Vulkan development/runtime support is not ready')
    if cm.get('GGML_OPENCL') == 'ON' and not caps.get('opencl'):
        blockers.append('OpenCL is not ready')
    return blockers


def profile_recommendation(profile, hw):
    name = profile.get('name','')
    if 'Intel SYCL' in name:
        return 'RECOMMENDED for the discrete Arc GPU: native Intel path via SYCL + Level Zero.'
    if 'AMD integrated' in name:
        return 'OPTIONAL: uses the integrated AMD GPU through Vulkan. Kept separate from ROCm because AMD Linux ROCm guidance does not generally support IGPs.'
    if 'AMD HIP' in name:
        return 'RECOMMENDED only for a supported discrete AMD GPU with a working ROCm stack.'
    if 'Vulkan' in name:
        return 'GOOD FALLBACK / portability option; usually less feature-complete or slower than a native vendor backend.'
    return 'Review the detected hardware and dependency contract before building.'


def print_profile_card(i, profile, hw, compact=False):
    blockers = profile_blockers(profile, hw)
    status = 'READY' if not blockers else 'BLOCKED'
    cm = profile.get('cmake', {})
    if compact:
        print(f"{i:2}. {profile.get('name','')} | score={profile.get('score',0):3} | {paint(status_mark(status)+' '+status, 'green' if status=='READY' else 'yellow' if status=='BLOCKED' else 'white', bold=True)}")
        print(f"    {profile.get('notes','')}")
        print(f"    Recommendation: {profile_recommendation(profile, hw)}")
        if blockers:
            print('    Blockers: ' + '; '.join(blockers))
        return
    print(f"\n[{i}] {profile.get('name','')}   [{status}]   score={profile.get('score',0)}")
    print(f"  Purpose: {profile.get('notes','')}")
    print(f"  Recommendation: {profile_recommendation(profile, hw)}")
    if blockers:
        print('  BLOCKERS: ' + '; '.join(blockers))
    print('  CMake:')
    for k,v in cm.items():
        print(f"    {k} = {v}")


def unified_build_view(rows, selected=None):
    print('\n=== BUILD MANAGER ===')
    if not rows:
        print('No generated builds.')
        return
    print(f"{'#':>2}  {'ID':34}  {'BACKEND':22}  {'STATUS':10}  {'JOBS':>4}  {'GPU'}")
    print('-'*110)
    for i,m in enumerate(rows,1):
        last = (m.get('results') or [{}])[-1]
        rc = last.get('exit_code')
        if rc == 0:
            st='BUILT'
        elif rc is None:
            st='READY'
        else:
            st='FAILED'
        targets = m.get('target_devices') or []
        if targets:
            gpu = ' / '.join(d.get('product','?') for d in targets)[:34]
        else:
            gpu = ' / '.join(g.get('product','?') for g in m.get('hardware',{}).get('gpus',[]))[:34]
        jobs = str(m.get('tuning',{}).get('jobs','?'))
        colour = 'green' if st=='BUILT' else 'yellow' if st=='READY' else 'red'
        print(f"{i:>2}  {m.get('id','')[:34]:34}  {m.get('profile_id','')[:22]:22}  {paint(st, colour, bold=True):10}  {jobs:>4}  {gpu}")
    if selected is not None:
        m=rows[selected]
        print('\n--- SELECTED BUILD ---')
        print(f"ID          : {m['id']}")
        print(f"Profile     : {m.get('name')}")
        print(f"Source      : {m.get('source_dir')}")
        print(f"Build dir   : {m.get('build_dir')}")
        print(f"Generator   : {m.get('generator','default')}")
        t=m.get('tuning',{})
        print(f"Performance : {t.get('jobs','?')} jobs | ccache={'ON' if t.get('ccache') else 'OFF'} | native={'ON' if t.get('native') else 'OFF'} | unity={'ON' if t.get('unity') else 'OFF'} | LTO={'ON' if t.get('lto') else 'OFF'}")
        print('CMake options:')
        for k,v in m.get('cmake',{}).items():
            print(f"  {k:34} = {v}")
        if m.get('results'):
            print('Last result:', json.dumps(m['results'][-1], indent=2))


def edit_build_interactive(m):
    catalogue = load_catalogue()
    by_key = {x.get('key'): x for x in catalogue if isinstance(x, dict)}
    cm = m.setdefault('cmake', {})
    backend = m.get('profile_id','')
    protected = {
        'CMAKE_C_COMPILER', 'CMAKE_CXX_COMPILER',
        'GGML_CUDA', 'GGML_HIP', 'GGML_SYCL', 'GGML_VULKAN', 'GGML_OPENCL'
    }

    def recommendations():
        rec = set()
        if 'intel-sycl' in backend:
            rec.update({'GGML_SYCL','GGML_SYCL_TARGET','GGML_SYCL_SUPPORT_LEVEL_ZERO','GGML_NATIVE','CMAKE_C_COMPILER','CMAKE_CXX_COMPILER'})
        elif 'amd-vulkan-igpu' in backend:
            rec.update({'GGML_VULKAN','GGML_NATIVE'})
        elif 'amd-hip' in backend:
            rec.update({'GGML_HIP','GGML_NATIVE'})
        elif 'nvidia-cuda' in backend:
            rec.update({'GGML_CUDA','GGML_NATIVE'})
        if m.get('tuning',{}).get('ccache'):
            rec.update({'CMAKE_C_COMPILER_LAUNCHER','CMAKE_CXX_COMPILER_LAUNCHER'})
        return rec

    recs = recommendations()
    items=[]
    for k,v in cm.items():
        item=by_key.get(k,{})
        if not isinstance(item,dict): item={}
        items.append((k,item,v))

    while True:
        print('\n=== CONFIGURATION EDITOR ===')
        print(f"Build   : {m.get('id','')}")
        print(f"Backend : {m.get('name',m.get('profile_id',''))}")
        print(f"Source  : {m.get('source_dir','')}")
        print('')
        print('Legend: [x] enabled  [ ] disabled  [=] value  ! protected  * recommended')
        print('')
        for i,(k,item,v) in enumerate(items,1):
            kind,mark=option_state(item,k,v,k in recs,k in protected)
            checked = str(v).upper() in {'ON','TRUE','1'}
            if kind=='bool':
                box='x' if checked else ' '
                prefix='!' if k in protected else '* ' if k in recs else '  '
                print(f"{i:2}. {prefix}[{box}] {k:<34} = {v:<8} {mark}")
            else:
                prefix='!' if k in protected else '* ' if k in recs else '  '
                print(f"{i:2}. {prefix}[=] {k:<34} = {str(v)[:28]:<28} {mark}")
            desc=catalogue_description(item)
            if desc: print(f"     {desc}")
            use=item.get('use_cases') or []
            if isinstance(use,str): use=[use]
            if use: print('     Use: ' + '; '.join(use[:3]))
            ex=item.get('examples') or []
            if isinstance(ex,str): ex=[ex]
            if ex: print(f"     Example: {ex[0]}")
        print('')
        print('Recommended for this build:')
        for k in sorted(recs):
            print(f"  * {k} = {cm.get(k,'AUTO')}  |  {by_key.get(k,{}).get('description','hardware-aware recommendation')}")
        print('')
        print('Actions: [t] toggle boolean(s)  [v] edit value  [r] restore recommendations  [a] apply/save  [c] cancel')
        action=normalise_menu_choice(safe_input('Action: ')).lower()
        if action=='c' or not action:
            return False
        if action=='t':
            raw=safe_input('Toggle option numbers (comma-separated): ').strip()
            for token in raw.split(','):
                try: idx=int(token.strip())
                except ValueError: continue
                if not (1<=idx<=len(items)): continue
                k,item,v=items[idx-1]
                if k in protected:
                    print(f'  {k}: protected backend/identity option.')
                    continue
                if option_kind(item,k,v)!='bool':
                    print(f'  {k}: value option, use [v].')
                    continue
                cm[k]='OFF' if str(v).upper() in {'ON','TRUE','1'} else 'ON'
                items[idx-1]=(k,item,cm[k])
        elif action=='v':
            raw=safe_input('Value option number: ').strip()
            try: idx=int(raw)
            except ValueError: continue
            if not (1<=idx<=len(items)): continue
            k,item,v=items[idx-1]
            if k in protected:
                print(f'  {k}: protected backend/identity option.')
                continue
            new=safe_input(f'New value for {k}',str(v)).strip()
            if new:
                cm[k]=new; items[idx-1]=(k,item,new)
        elif action=='r':
            for k in recs:
                if k=='GGML_SYCL': cm[k]='ON'
                elif k=='GGML_SYCL_TARGET': cm[k]='INTEL'
                elif k=='GGML_SYCL_SUPPORT_LEVEL_ZERO': cm[k]='ON'
                elif k=='GGML_VULKAN': cm[k]='ON'
                elif k in {'GGML_HIP','GGML_CUDA','GGML_NATIVE'}: cm[k]='ON'
                elif k=='CMAKE_C_COMPILER_LAUNCHER' and m.get('tuning',{}).get('ccache'): cm[k]='ccache'
                elif k=='CMAKE_CXX_COMPILER_LAUNCHER' and m.get('tuning',{}).get('ccache'): cm[k]='ccache'
            items=[(k,by_key.get(k,{}),cm[k]) for k in cm]
            print('Recommended settings restored.')
        elif action=='a':
            m['command']=build_cmd(m)
            m['edited']=datetime.now(timezone.utc).isoformat()
            (BUILDS/m['id']/ 'manifest.json').write_text(json.dumps(m,indent=2))
            print('Configuration saved.')
            return True
    


def gpu_form_factor(hw):
    """Return dominant GPU form factor for mixed-GPU systems."""
    gpus = hw.get('gpus', []) or []
    if any(g.get('form_factor') == 'discrete' for g in gpus):
        return 'discrete'
    if any(g.get('form_factor') == 'integrated' for g in gpus):
        return 'integrated'
    return 'unknown'


def profile_ready(profile, hw):
    """A profile is buildable only when all current backend blockers are absent."""
    return not profile_blockers(profile, hw)


def target_name(hw):
    gpu_text = ' '.join(json.dumps(g).lower() for g in hw.get('gpus', []))
    caps = hw.get('capabilities', {})
    if caps.get('cuda') or 'nvidia' in gpu_text:
        return 'nvidia-cuda'
    amd_discrete = any(g.get('form_factor') == 'discrete' and ('amd' in json.dumps(g).lower() or 'radeon' in json.dumps(g).lower()) for g in hw.get('gpus', []))
    if amd_discrete and caps.get('rocm'):
        return 'amd-hip'
    if caps.get('sycl') and ('intel' in gpu_text or caps.get('intel')):
        return 'intel-sycl'
    if caps.get('vulkan') and ('intel' in gpu_text or 'amd' in gpu_text or 'radeon' in gpu_text):
        return 'gpu-vulkan'
    return 'unsupported-accelerator' if hw.get('accelerator_present') else 'cpu-only'


def make_profiles(hw):
    caps = hw.get('capabilities', {})
    gpu_text = ' '.join(json.dumps(g).lower() for g in hw.get('gpus', []))
    form = gpu_form_factor(hw)
    profiles = []

    def base(label, key, notes, score=50):
        return {'id': key, 'name': label, 'score': score, 'notes': notes, 'cmake': {'CMAKE_BUILD_TYPE': 'Release'}}

    # Deliberately NO CPU fallback profiles. This project is accelerator-first.
    if caps.get('cuda') or 'nvidia' in gpu_text:
        p = base(f'NVIDIA CUDA ({form})', 'nvidia-cuda', 'CUDA GPU acceleration; native CUDA architecture by default.', 100)
        p['cmake'].update({'GGML_CUDA': 'ON', 'GGML_NATIVE': 'ON'})
        if shutil.which('nvidia-smi'):
            p['cmake']['GGML_CUDA_GRAPHS'] = 'ON'
        profiles.append(p)
        np = base('NVIDIA CUDA Portable', 'nvidia-cuda-portable', 'CUDA build intended to cover multiple NVIDIA GPU generations.', 90)
        np['cmake'].update({'GGML_CUDA': 'ON', 'GGML_NATIVE': 'OFF'})
        profiles.append(np)

    amd_discrete = any(g.get('form_factor') == 'discrete' and ('amd' in json.dumps(g).lower() or 'radeon' in json.dumps(g).lower()) for g in hw.get('gpus', []))
    if amd_discrete and (caps.get('rocm') or rocm_environment().get('available')):
        p = base(f'AMD HIP / ROCm ({form})', 'amd-hip', 'ROCm/HIP acceleration for discrete AMD GPUs.', 100)
        p['cmake'].update({'GGML_HIP': 'ON', 'GGML_NATIVE': 'ON', 'GGML_HIP_GRAPHS': 'ON'})
        p['environment'] = {}
        roc = rocm_environment()
        if roc.get('root'):
            root=Path(roc['root'])
            p['environment'].update({'ROCM_PATH':str(root),'HIP_PATH':str(root)})
            clang=root/'llvm/bin/clang'; clangxx=root/'llvm/bin/clang++'
            if clang.exists() and clangxx.exists():
                p['cmake']['CMAKE_C_COMPILER']=str(clang)
                p['cmake']['CMAKE_CXX_COMPILER']=str(clangxx)
        profiles.append(p)
        if caps.get('vulkan'):
            v = base('AMD Vulkan Fallback', 'amd-vulkan', 'Vulkan alternative when ROCm is absent, problematic, or intentionally avoided.', 70)
            v['cmake'].update({'GGML_VULKAN': 'ON', 'GGML_NATIVE': 'ON'})
            profiles.append(v)
    if any(g.get('form_factor') == 'integrated' and ('amd' in json.dumps(g).lower() or 'radeon' in json.dumps(g).lower()) for g in hw.get('gpus', [])):
        v = base('AMD integrated GPU / Vulkan', 'amd-vulkan-igpu', 'Use the integrated AMD Radeon GPU through Vulkan. ROCm/HIP is deliberately not the default path for an AMD IGP.', 72)
        v['cmake'].update({'GGML_VULKAN': 'ON', 'GGML_NATIVE': 'ON'})
        v['optional'] = True
        profiles.append(v)

    if caps.get('intel') or 'intel' in gpu_text:
        if caps.get('sycl'):
            p = base(f'Intel SYCL / oneAPI ({form})', 'intel-sycl', 'Intel GPU acceleration through SYCL and Level Zero.', 100)
            p['cmake'].update({'GGML_SYCL': 'ON', 'GGML_SYCL_TARGET': 'INTEL', 'GGML_SYCL_SUPPORT_LEVEL_ZERO': 'ON', 'GGML_NATIVE': 'ON', 'CMAKE_C_COMPILER': 'icx', 'CMAKE_CXX_COMPILER': 'icpx'})
            p['environment'] = dict(discover_oneapi_environment().get('environment', {}))
            profiles.append(p)
        if caps.get('vulkan'):
            v = base('Intel Vulkan', 'intel-vulkan', 'Vulkan path for Intel GPU, useful as an alternate backend.', 75)
            v['cmake'].update({'GGML_VULKAN': 'ON', 'GGML_NATIVE': 'ON'})
            profiles.append(v)

    if caps.get('vulkan') and profiles == []:
        p = base('Generic Vulkan', 'vulkan', 'Portable GPU backend for Vulkan-capable hardware.', 65)
        p['cmake'].update({'GGML_VULKAN': 'ON', 'GGML_NATIVE': 'ON'})
        profiles.append(p)

    if caps.get('opencl') and profiles == []:
        p = base('OpenCL', 'opencl', 'OpenCL backend; useful on platforms where Vulkan/CUDA/HIP/SYCL are unavailable.', 55)
        p['cmake'].update({'GGML_OPENCL': 'ON', 'GGML_NATIVE': 'ON'})
        profiles.append(p)

    amd_discrete_present = any(g.get('form_factor') == 'discrete' and ('amd' in json.dumps(g).lower() or 'radeon' in json.dumps(g).lower()) for g in hw.get('gpus', []))
    if amd_discrete_present and caps.get('vulkan') and caps.get('rocm'):
        profiles.append({'id': 'amd-dual-hip-vulkan', 'name': 'AMD HIP + Vulkan', 'score': 82,
                         'notes': 'Build both backends; runtime can choose the appropriate device.',
                         'cmake': {'CMAKE_BUILD_TYPE': 'Release', 'GGML_HIP': 'ON', 'GGML_VULKAN': 'ON', 'GGML_NATIVE': 'ON', 'CMAKE_C_COMPILER': 'clang', 'CMAKE_CXX_COMPILER': 'clang++'},
                         'environment': dict(discover_oneapi_environment().get('environment', {}))})
    if ('intel' in gpu_text or caps.get('intel')) and caps.get('vulkan') and caps.get('sycl'):
        profiles.append({'id': 'intel-dual-sycl-vulkan', 'name': 'Intel SYCL + Vulkan', 'score': 86,
                         'notes': 'Build both Intel GPU backends; useful for fallback and A/B testing.',
                         'cmake': {'CMAKE_BUILD_TYPE': 'Release', 'GGML_SYCL': 'ON', 'GGML_SYCL_TARGET': 'INTEL', 'GGML_SYCL_SUPPORT_LEVEL_ZERO': 'ON', 'GGML_VULKAN': 'ON', 'GGML_NATIVE': 'ON', 'CMAKE_C_COMPILER': 'icx', 'CMAKE_CXX_COMPILER': 'icpx'},
                         'environment': dict(discover_oneapi_environment().get('environment', {}))})
    return sorted(profiles, key=lambda x: (-x['score'], x['id']))


def build_environment(manifest):
    env = os.environ.copy()
    # Reload oneAPI's environment for non-interactive builds. Merely finding icpx on disk
    # is not sufficient because SYCL/oneDNN/MKL shared libraries also need PATH/LD_LIBRARY_PATH.
    setvars = manifest.get('environment', {}).get('ONEAPI_SET_VARS')
    if setvars and Path(setvars).is_file():
        cmd=['bash','-lc', 'source ' + shlex_quote(setvars) + ' >/dev/null 2>&1; env -0']
        out, _, rc = run(cmd, 30)
        if rc==0 and out:
            for item in out.split('\0'):
                if '=' in item:
                    k,v=item.split('=',1); env[k]=v
    for k, v in manifest.get('environment', {}).items():
        if v and k != 'ONEAPI_SET_VARS': env[k] = str(v)
    return env


def build_cmd(manifest):
    source = manifest['source_dir']
    bdir = Path(manifest['build_dir'])
    args = ['cmake', '-S', source, '-B', str(bdir)]
    generator = manifest.get('generator')
    if generator and generator != 'Unix Makefiles':
        args += ['-G', generator]
    args.append(f"-DCMAKE_BUILD_TYPE={manifest['cmake'].get('CMAKE_BUILD_TYPE','Release')}")
    for k, v in manifest['cmake'].items():
        if k == 'CMAKE_BUILD_TYPE':
            continue
        args.append(f'-D{k}={v}')
    return args


def emit_build(profile, hw, source_dir, repo_name='llama.cpp'):
    blockers = profile_blockers(profile, hw)
    if blockers:
        raise RuntimeError('Profile is not buildable: ' + '; '.join(blockers))
    BUILDS.mkdir(exist_ok=True)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    bid = f"{profile['id']}-{stamp}"
    root = BUILDS / bid
    root.mkdir(parents=True, exist_ok=False)
    tuning = recommended_build_tuning()
    manifest = {
        'id': bid,
        'profile_id': profile['id'],
        'name': profile['name'],
        'created': datetime.now(timezone.utc).isoformat(),
        'source_dir': str(Path(source_dir).resolve()),
        'build_dir': str((root / 'cmake').resolve()),
        'repository': repo_name,
        'notes': profile['notes'],
        'hardware': hw,
        'gpu_form_factor': gpu_form_factor(hw),
        'cmake': dict(profile['cmake']),
        'environment': profile.get('environment', {}),
    }
    apply_tuning_to_manifest(manifest, tuning)
    gpu_matches=[]
    profile_id=profile.get('id','')
    for g in hw.get('gpus',[]):
        blob=json.dumps(g).lower()
        if profile_id == 'amd-vulkan-igpu' and g.get('form_factor')=='integrated' and ('amd' in blob or 'radeon' in blob): gpu_matches.append(g)
        elif profile_id.startswith('intel') and g.get('form_factor')=='discrete' and 'intel' in blob: gpu_matches.append(g)
        elif profile_id.startswith('amd') and profile_id!='amd-vulkan-igpu' and g.get('form_factor')=='discrete' and ('amd' in blob or 'radeon' in blob): gpu_matches.append(g)
        elif profile_id.startswith('nvidia') and 'nvidia' in blob: gpu_matches.append(g)
    manifest['target_devices'] = gpu_matches
    manifest['dependency_contract'] = dependency_contract(hw, profile, manifest['tuning'])
    manifest['command'] = build_cmd(manifest)
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    script = root / 'run.sh'
    script.write_text('#!/usr/bin/env bash\nset -euo pipefail\ncd "$(dirname "$0")/.."\npython3 "../lib/llama_forge.py" build-run "' + bid + '"\n')
    script.chmod(0o755)
    return manifest


def require_accelerator(hw, interactive=False):
    if hw.get('accelerator_present'):
        return True
    print('\nNO ACCELERATOR DETECTED')
    print('No usable GPU/NPU/TPU or accelerator capability was found.')
    print('CPU-only builds are disabled by design. No build will be created or run.')
    if interactive:
        print('You can still inspect hardware, the switch catalogue, and existing build folders.')
    return False




def system_resources():
    cpus = os.cpu_count() or 1
    mem_gb = 0.0
    try:
        mem_kb = 0
        for line in read_file('/proc/meminfo', 20000).splitlines():
            if line.startswith('MemTotal:'):
                mem_kb = int(line.split()[1]); break
        mem_gb = mem_kb / (1024 * 1024)
    except Exception:
        pass
    return {'cpu_threads': cpus, 'memory_gb': round(mem_gb, 1)}


def recommended_build_tuning(responsiveness='balanced'):
    r = system_resources()
    threads = max(1, int(r['cpu_threads']))
    # Do not automatically consume every logical CPU. This makes the forge usable
    # on a desktop while still compiling aggressively. Users can opt into all cores.
    if responsiveness == 'maximum':
        jobs = threads
    elif responsiveness == 'responsive':
        jobs = max(1, threads - 2) if threads > 4 else max(1, threads // 2)
    else:
        jobs = max(1, round(threads * 0.75))
    if r['memory_gb'] and r['memory_gb'] < 8:
        jobs = min(jobs, 2)
    elif r['memory_gb'] and r['memory_gb'] < 16:
        jobs = min(jobs, 4)
    return {
        'generator': 'Ninja' if shutil.which('ninja') else 'Unix Makefiles',
        'jobs': jobs,
        'ccache': bool(shutil.which('ccache')),
        'native': True,
        'unity': False,
        'lto': False,
        'responsiveness': responsiveness,
        'cpu_threads': threads,
        'memory_gb': r['memory_gb'],
    }

def dependency_contract(hw, profile, tuning=None):
    caps = hw.get('capabilities', {})
    contract = {
        'os': {'id': hw['os']['id'], 'version_id': hw['os']['version_id']},
        'accelerators': {
            'gpu': hw.get('gpus', []), 'npu': hw.get('npus', []), 'tpu': hw.get('tpus', [])
        },
        'backend': profile['id'],
        'required_tools': [],
        'runtime_checks': [],
        'optional_tools': ['ccache', 'ninja'],
        'blocking_policy': 'No CPU fallback. Build is blocked when required accelerator dependencies are missing.',
    }
    cmake = profile.get('cmake', {})
    if cmake.get('GGML_CUDA') == 'ON':
        contract['required_tools'] += ['nvidia-smi', 'nvcc']
        contract['runtime_checks'] += ['NVIDIA driver', 'CUDA toolkit']
    if cmake.get('GGML_HIP') == 'ON':
        contract['required_tools'] += ['hipcc', 'rocminfo']
        contract['runtime_checks'] += ['AMD ROCm/HIP runtime', '/dev/kfd']
    if cmake.get('GGML_SYCL') == 'ON':
        contract['required_tools'] += ['icpx', 'sycl-ls']
        contract['runtime_checks'] += ['Intel oneAPI SYCL compiler', 'Level Zero loader']
    if cmake.get('GGML_VULKAN') == 'ON':
        contract['required_tools'] += ['vulkaninfo']
        contract['runtime_checks'] += ['Vulkan ICD/runtime']
    if cmake.get('GGML_OPENCL') == 'ON':
        contract['required_tools'] += ['clinfo']
        contract['runtime_checks'] += ['OpenCL ICD/runtime']
    contract['tuning'] = tuning or recommended_build_tuning()
    return contract


def apply_tuning_to_manifest(m, tuning):
    m['tuning'] = tuning
    cm = m.setdefault('cmake', {})
    if tuning.get('generator') == 'Ninja':
        m['generator'] = 'Ninja'
    else:
        m['generator'] = 'Unix Makefiles'
    cm['CMAKE_BUILD_TYPE'] = 'Release'
    cm['GGML_NATIVE'] = 'ON' if tuning.get('native', True) else 'OFF'
    if tuning.get('ccache'):
        cm['CMAKE_C_COMPILER_LAUNCHER'] = 'ccache'
        cm['CMAKE_CXX_COMPILER_LAUNCHER'] = 'ccache'
    else:
        cm.pop('CMAKE_C_COMPILER_LAUNCHER', None)
        cm.pop('CMAKE_CXX_COMPILER_LAUNCHER', None)
    if tuning.get('unity'):
        cm['CMAKE_UNITY_BUILD'] = 'ON'
        cm['CMAKE_UNITY_BUILD_BATCH_SIZE'] = str(tuning.get('unity_batch_size', 8))
    else:
        cm.pop('CMAKE_UNITY_BUILD', None)
        cm.pop('CMAKE_UNITY_BUILD_BATCH_SIZE', None)
    cm['CMAKE_INTERPROCEDURAL_OPTIMIZATION'] = 'ON' if tuning.get('lto') else 'OFF'
    m['environment'] = dict(m.get('environment', {}))
    m['environment']['CMAKE_BUILD_PARALLEL_LEVEL'] = str(max(1, int(tuning.get('jobs', 1))))
    return m


def configure_performance(m=None, level=None):
    base = recommended_build_tuning('balanced')
    fast = recommended_build_tuning('maximum')
    responsive = recommended_build_tuning('responsive')
    levels = {
        '1': ('Balanced / desktop-friendly', {**base, 'ccache': bool(shutil.which('ccache')), 'native': True, 'unity': False, 'lto': False}),
        '2': ('Fast compile', {**fast, 'ccache': bool(shutil.which('ccache')), 'native': True, 'unity': True, 'unity_batch_size': 8, 'lto': False}),
        '3': ('Maximum runtime optimisation', {**base, 'ccache': bool(shutil.which('ccache')), 'native': True, 'unity': False, 'lto': True}),
        '4': ('Responsive / low system impact', {**responsive, 'ccache': bool(shutil.which('ccache')), 'native': True, 'unity': False, 'lto': False}),
        '5': ('Maximum CPU parallelism', {**fast, 'ccache': bool(shutil.which('ccache')), 'native': True, 'unity': False, 'lto': False}),
    }
    if level not in levels:
        return None
    return levels[level]


def apply_perf_to_all():
    rows = build_rows()
    print('\n=== PERFORMANCE TUNING ===')
    r = system_resources()
    print(f"Detected resources: {r['cpu_threads']} logical CPU threads, {r['memory_gb']:.1f} GiB RAM")
    print(f"Ninja: {'installed' if shutil.which('ninja') else 'not installed'} | ccache: {'installed' if shutil.which('ccache') else 'not installed'}")
    print('\nProfiles:')
    profiles = {
        '1': ('Balanced / desktop-friendly', recommended_build_tuning('balanced')),
        '2': ('Fast compile', recommended_build_tuning('maximum') | {'ccache': bool(shutil.which('ccache')), 'unity': True, 'unity_batch_size': 8}),
        '3': ('Maximum runtime optimisation', recommended_build_tuning('balanced') | {'ccache': bool(shutil.which('ccache')), 'lto': True}),
        '4': ('Responsive / low system impact', recommended_build_tuning('responsive')),
        '5': ('Maximum CPU parallelism', recommended_build_tuning('maximum')),
    }
    for k, (name, cfg) in profiles.items():
        print(f"  {k}. {name}: {cfg['jobs']} parallel jobs, generator={cfg['generator']}, ccache={'ON' if cfg.get('ccache') else 'OFF'}, native={'ON' if cfg.get('native', True) else 'OFF'}, unity={'ON' if cfg.get('unity') else 'OFF'}, LTO={'ON' if cfg.get('lto') else 'OFF'}")
    if not rows:
        print('\nNo generated builds yet. Choose a profile here later, after creating builds.')
        return
    level = safe_input('\nProfile (0 to cancel): ').strip()
    if level == '0':
        print('Performance tuning cancelled.')
        return
    result = configure_performance(level=level)
    if not result:
        print('Invalid profile.')
        return
    name, cfg = result
    print(f"\nSelected: {name}")
    print(f"  CPU threads: {cfg.get('cpu_threads')} | build jobs: {cfg.get('jobs')} | responsiveness: {cfg.get('responsiveness')}")
    print('  This changes build parallelism and compiler/cache settings. It does not throttle the GPU runtime.')
    answer = safe_input(f'Apply to {len(rows)} existing build(s)? [y/N]: ').strip().lower()
    if answer != 'y':
        print('No builds changed.')
        return
    changed = 0
    for n, m in enumerate(rows, 1):
        print(f"[{n}/{len(rows)}] Updating {m['id']}...", flush=True)
        build_root = Path(m['build_dir'])
        if build_root.exists() and (build_root / 'CMakeCache.txt').exists():
            backup = build_root.parent / ('cmake.previous-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
            try:
                build_root.rename(backup)
                print(f"  Preserved previous CMake tree: {backup}")
            except OSError as e:
                print(f"  Could not preserve existing CMake tree: {e}")
                continue
        apply_tuning_to_manifest(m, cfg)
        m['dependency_contract'] = dependency_contract(m['hardware'], {'id': m.get('profile_id', 'custom'), 'cmake': m.get('cmake', {})}, m['tuning'])
        m['command'] = build_cmd(m)
        (BUILDS / m['id'] / 'manifest.json').write_text(json.dumps(m, indent=2))
        changed += 1
    print(f'\nApplied {name} tuning to {changed}/{len(rows)} build(s).')
    if not cfg.get('ccache'):
        print('Note: ccache is not installed, so repeated-build caching is unavailable.')


def cmd_scan(_):
    print(json.dumps(scan_hardware(), indent=2))


def cmd_generate(args):
    hw = scan_hardware()
    if not require_accelerator(hw):
        return
    if not hw['os']['supported_target']:
        print(f"WARNING: detected {hw['os']['name']}; generator is currently targeted at Ubuntu 24.04/26.04.", file=sys.stderr)
    inv, missing, required = dependency_status(hw, progress=progress_line)
    if missing:
        print('WARNING: missing prerequisites: ' + ', '.join(missing))
        print('Use the interactive dependency manager before building.')
    profiles = make_profiles(hw)
    if not profiles:
        print('\nAccelerator hardware was detected, but no supported llama.cpp backend profile matched it.')
        print('No CPU fallback will be generated.')
        return
    print(json.dumps({'hardware': hw, 'profiles': profiles}, indent=2))
    if args.source:
        source = Path(args.source).expanduser()
        if not (source / 'CMakeLists.txt').exists():
            raise SystemExit(f'Not a llama.cpp source tree: {source}')
        for p in profiles:
            m = emit_build(p, hw, source)
            print(f"created {m['id']}")


def build_rows():
    rows = []
    for d in sorted(BUILDS.iterdir() if BUILDS.exists() else []):
        m = d / 'manifest.json'
        if m.exists():
            x = json.loads(m.read_text())
            rows.append(x)
    return rows


def cmd_list(_):
    rows = build_rows()
    if not rows:
        print('No generated builds.')
        return
    for x in rows:
        print(f"{x['id']}\t{x['name']}")


def cmd_show(args):
    p = BUILDS / args.id / 'manifest.json'
    if not p.exists():
        raise SystemExit('Build not found: ' + args.id)
    print(p.read_text())


def cmd_delete(args):
    p = BUILDS / args.id
    if not p.exists():
        raise SystemExit('Build not found: ' + args.id)
    shutil.rmtree(p)
    print('deleted', args.id)


def backend_compile_preflight(manifest, env, log_path):
    """Compile one representative translation unit with the exact configured toolchain.

    This is intentionally small compared with a full llama.cpp build. It catches compiler/
    SYCL/HIP/CUDA environment problems and hard compiler crashes before the main compilation.
    """
    bdir=Path(manifest['build_dir'])
    ccdb=bdir/'compile_commands.json'
    if not ccdb.exists():
        print('[PREFLIGHT] compile_commands.json not available; skipping representative TU check.')
        return True
    try:
        commands=json.loads(ccdb.read_text())
    except Exception as e:
        print(f'[PREFLIGHT] Could not read compile_commands.json: {e}')
        return True
    backend=manifest.get('profile_id','')
    preferred=[]
    if 'sycl' in backend:
        preferred=['ggml/src/ggml-sycl/element_wise.cpp','ggml/src/ggml-sycl/common.cpp']
    elif 'hip' in backend:
        preferred=['ggml/src/ggml-hip/ggml-hip.cpp']
    elif 'cuda' in backend:
        preferred=['ggml/src/ggml-cuda/ggml-cuda.cu']
    else:
        preferred=['ggml/src/ggml.cpp']
    chosen=None
    for pref in preferred:
        for item in commands:
            f=item.get('file','')
            if f.endswith(pref) or pref in f:
                chosen=item; break
        if chosen: break
    if not chosen:
        # Prefer a non-trivial ggml source file rather than arbitrary examples.
        for item in commands:
            f=item.get('file','')
            if '/ggml/' in f and f.endswith(('.cpp','.cc','.c','.cu')):
                chosen=item; break
    if not chosen:
        print('[PREFLIGHT] No suitable translation unit found; continuing.')
        return True
    command=chosen.get('command')
    if not command:
        args=chosen.get('arguments') or []
    else:
        args=shlex.split(command)
    if not args:
        print('[PREFLIGHT] Empty compile command; continuing.')
        return True
    cleaned=[]
    i=0
    while i < len(args):
        a=args[i]
        if a in {'-o','-MF','-MT'} and i+1 < len(args):
            i += 2; continue
        if a in {'-MD','-MMD'}:
            i += 1; continue
        # Avoid build system's depfile-only flags in syntax check.
        cleaned.append(a)
        i += 1
    # Replace the compile action with syntax-only. Keep the original source and all include/define flags.
    cleaned=[a for a in cleaned if a not in {'-c'}]
    cleaned.append('-fsyntax-only')
    print(f"[PREFLIGHT] Representative compiler check: {Path(chosen.get('file','')).name}")
    print('[PREFLIGHT] Running the configured compiler once before the full build...')
    logf=open(log_path,'a',encoding='utf-8')
    logf.write('\n=== BACKEND COMPILE PREFLIGHT ===\n')
    logf.write(' '.join(shlex.quote(x) for x in cleaned) + '\n')
    logf.flush()
    start=time.monotonic()
    try:
        proc=subprocess.run(cleaned, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180, env=env)
        output=proc.stdout or ''
    except subprocess.TimeoutExpired as e:
        output=(e.stdout or '') if isinstance(e.stdout,str) else ''
        proc=None
        logf.write(output+'\n')
        logf.close()
        print('[PREFLIGHT] TIMEOUT after 180s. Full build was not started.')
        return False
    logf.write(output+'\n')
    logf.close()
    elapsed=time.monotonic()-start
    if output:
        for line in output.splitlines()[-20:]:
            if 'warning' in line.lower() or 'error' in line.lower() or 'fatal' in line.lower():
                print('[PREFLIGHT] '+line)
    if proc.returncode == 0:
        print(f'[PREFLIGHT] PASS in {elapsed:.1f}s. Full build may proceed.')
        return True
    print(f'[PREFLIGHT] FAIL with exit {proc.returncode} after {elapsed:.1f}s.')
    if proc.returncode < 0:
        print(f'[PREFLIGHT] Compiler terminated by signal {-proc.returncode}. This is a compiler/toolchain failure, not a llama.cpp configure failure.')
    if 'sycl' in backend:
        print('[PREFLIGHT] Recovery recommendation: retry with 1 job, ccache OFF, unity OFF and LTO OFF; then re-run the representative compiler test.')
    else:
        print('[PREFLIGHT] Recovery recommendation: use the conservative performance profile and re-run preflight.')
    print(f'[PREFLIGHT] Full build was NOT started. Log: {log_path}')
    return False


def stream_process(cmd, env=None, log_path=None, phase='BUILD'):
    start = time.monotonic()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=env)
    logf = open(log_path, 'a', encoding='utf-8') if log_path else None
    last_pct = None
    try:
        for raw in proc.stdout:
            line = raw.rstrip()
            if logf:
                logf.write(line + '\n'); logf.flush()
            m = re.search(r'\[\s*(\d+)%\]', line)
            prefix = f'[{phase}]'
            if m and m.group(1) != last_pct:
                last_pct = m.group(1)
                print(f'{prefix} {last_pct:>3}% | {line}', flush=True)
            elif line.startswith('--') or 'error:' in line.lower() or 'warning:' in line.lower() or line.startswith('FAILED'):
                print(f'{prefix} {line}', flush=True)
        rc = proc.wait()
    finally:
        if logf: logf.close()
    elapsed = time.monotonic() - start
    print(f'[{phase}] finished with exit {rc} in {elapsed:.1f}s', flush=True)
    return rc, elapsed



def parse_failure_diagnostics(text):
    lines=text.splitlines(); low=text.lower()
    d={'kind':'unknown','targets':[],'link_lines':[],'symbols':[],'libraries':[]}
    for ln in lines:
        m=re.search(r'FAILED:.*?(?:bin/)?([A-Za-z0-9._-]+)$',ln)
        if m: d['targets'].append(m.group(1))
        ll=ln.lower()
        if any(x in ll for x in ('linker command failed','cannot find -l','undefined reference','ld:','collect2:')): d['link_lines'].append(ln)
        m=re.search(r"undefined reference to [`']([^`']+)[`']",ln)
        if m: d['symbols'].append(m.group(1))
        m=re.search(r"cannot find -l:?([A-Za-z0-9_+.-]+)",ln)
        if m: d['libraries'].append(m.group(1))
        m=re.search(r'(/[^\s:]+\.so(?:\.[0-9.]+)?)',ln)
        if m: d['libraries'].append(m.group(1))
    d['targets']=list(dict.fromkeys(d['targets'][-10:]))
    if any(x in low for x in ('undefined reference','linker command failed','cannot find -l')): d['kind']='link'
    elif any(x in low for x in ('segmentation fault','internal compiler error','clang frontend command failed')): d['kind']='compiler_crash'
    elif 'fatal error:' in low or 'no such file or directory' in low: d['kind']='missing_dependency'
    return d


def diagnose_build_failure(manifest,log_path,env):
    print('\nBUILD FAILED. The build directory and build.log were preserved for diagnosis.')
    text=Path(log_path).read_text(errors='replace') if Path(log_path).exists() else ''
    d=parse_failure_diagnostics(text)
    if d['kind']=='link':
        print('[DIAGNOSIS] Link stage failure detected.')
        for ln in d['link_lines'][-10:]: print('  '+ln[:300])
        if d['targets']: print('[DIAGNOSIS] Failed targets: '+', '.join(d['targets']))
        if d['libraries']: print('[DIAGNOSIS] Referenced libraries: '+', '.join(dict.fromkeys(d['libraries'][-8:])))
        if d['symbols']: print('[DIAGNOSIS] Unresolved symbols: '+', '.join(dict.fromkeys(d['symbols'][-8:])))
    elif d['kind']=='compiler_crash': print('[DIAGNOSIS] Compiler/toolchain crash detected.')
    elif d['kind']=='missing_dependency': print('[DIAGNOSIS] Missing compiler/development dependency detected.')
    else: print('[DIAGNOSIS] Unknown failure signature; complete log preserved.')
    if 'intel-sycl' in manifest.get('profile_id','') and d['kind']=='link':
        print('[RECOVERY] Intel SYCL: inspecting oneAPI TBB/MKL linkage and attempting a bounded local repair.')
    print(f'[DIAGNOSIS] Log: {log_path}')
    return d


def _candidate_library_dirs(env):
    dirs=[]
    for key in ('LD_LIBRARY_PATH','LIBRARY_PATH'):
        for item in str(env.get(key,'')).split(':'):
            if item and Path(item).is_dir() and item not in dirs: dirs.append(item)
    root=Path('/opt/intel/oneapi/tbb')
    if root.exists():
        for pth in root.glob('*/lib/**'):
            if pth.is_dir() and str(pth) not in dirs: dirs.append(str(pth))
    return dirs


def _symbol_is_exported(lib,symbol):
    out,_,rc=run(['nm','-D','--defined-only',str(lib)],12)
    if rc!=0: return False
    # nm may emit ABI decorations or version suffixes; accept an exact symbol
    # or a trailing version marker after the actual C++ symbol.
    for line in out.splitlines():
        if symbol in line:
            return True
    return False


def _ldd_resolution(lib, env):
    out, err, rc = run(['ldd', str(lib)], 12, env=env)
    resolved = {}
    if rc != 0:
        return resolved
    for line in out.splitlines():
        m = re.match(r'\s*(lib[^ ]+\.so(?:\.[0-9.]+)?)\s*=>\s*(/[^ ]+)', line)
        if m:
            resolved[m.group(1)] = m.group(2)
    return resolved


def _readelf_needed(lib, env):
    out, _, rc = run(['readelf','-d',str(lib)], 12, env=env)
    if rc != 0: return []
    return re.findall(r'Shared library: \[(lib[^]]+)\]', out)


def _candidate_tbb_providers(env, symbol, offending_lib=None):
    candidates=[]
    dirs=_candidate_library_dirs(env)
    # Prefer the same tree as the oneAPI MKL/TBB provider when possible.
    if offending_lib:
        parent=Path(offending_lib).parent
        if parent.is_dir() and str(parent) not in dirs: dirs.insert(0,str(parent))
    for d in dirs:
        candidates += list(Path(d).glob('libtbb.so')) + list(Path(d).glob('libtbb.so.*'))
    unique=[]
    seen=set()
    for lib in sorted(candidates, key=lambda x: (0 if 'oneapi' in str(x) else 1, str(x))):
        key=str(lib)
        if key in seen or not lib.is_file(): continue
        seen.add(key); unique.append(lib)
    providers=[]
    for lib in unique:
        if _symbol_is_exported(lib,symbol):
            soname_out,_,rc=run(['readelf','-d',str(lib)],12,env=env)
            soname=None
            if rc==0:
                m=re.search(r'SONAME.*\[(lib[^]]+)\]',soname_out)
                soname=m.group(1) if m else None
            providers.append((lib,soname))
    return providers


def repair_intel_tbb_link(manifest,env,diag):
    if 'intel-sycl' not in manifest.get('profile_id','') or not diag.get('symbols'): return None
    symbol=diag['symbols'][0]
    offending_lib=next((x for x in diag.get('libraries',[]) if str(x).endswith('.so') or '.so.' in str(x)), None)
    if offending_lib and not Path(offending_lib).is_file(): offending_lib=None
    if offending_lib:
        print(f'[AUTO-REPAIR] Inspecting {offending_lib} dependency graph...')
        needed=_readelf_needed(offending_lib,env)
        if needed: print('[AUTO-REPAIR] DT_NEEDED: '+', '.join(needed))
        resolved=_ldd_resolution(offending_lib,env)
        if resolved:
            for name,path in resolved.items():
                if 'libtbb' in name:
                    print(f'[AUTO-REPAIR] Current TBB resolution: {name} -> {path}')
                    if not _symbol_is_exported(path,symbol):
                        print(f'[AUTO-REPAIR] Current provider does not export the unresolved symbol.')
    providers=_candidate_tbb_providers(env,symbol,offending_lib)
    if not providers:
        print(f'[AUTO-REPAIR] No local TBB library exports {symbol}.')
        return None
    lib,soname=providers[0]
    libdir=str(lib.parent); lname=lib.name
    add=f'-L{libdir} -Wl,-rpath,{libdir} -Wl,-rpath-link,{libdir} -l:{lname}'
    cm=manifest.setdefault('cmake',{})
    for key in ('CMAKE_EXE_LINKER_FLAGS','CMAKE_SHARED_LINKER_FLAGS'):
        old=str(cm.get(key,'')).strip()
        if add not in old: cm[key]=(old+' '+add).strip()
    menv=manifest.setdefault('environment',{})
    old=str(menv.get('LD_LIBRARY_PATH',env.get('LD_LIBRARY_PATH','')))
    paths=[libdir]+[x for x in old.split(':') if x and x != libdir]
    menv['LD_LIBRARY_PATH']=':'.join(paths)
    manifest.setdefault('repair_history',[]).append({
        'time':datetime.now(timezone.utc).isoformat(),
        'type':'intel_tbb_link',
        'symbol':symbol,
        'library':str(lib),
        'soname':soname,
        'offending_library':offending_lib,
        'action':'explicit_tbb_link_rpath_rpath_link',
    })
    print(f'[AUTO-REPAIR] Found matching TBB symbol provider: {lib}')
    print(f'[AUTO-REPAIR] SONAME: {soname or "unknown"}')
    print(f'[AUTO-REPAIR] Added linker search/RPATH: {libdir}')
    return 'intel_tbb_link'


def link_target_preflight(manifest, env, targets, log_path):
    build_dir=manifest.get('build_dir')
    if not build_dir or not Path(build_dir).is_dir(): return True
    target=next((t for t in targets if re.match(r'^[A-Za-z0-9_.+-]+$', t)), None)
    if not target:
        return True
    if manifest.get('generator') != 'Ninja' or not shutil.which('ninja'):
        return True
    print(f'[PREFLIGHT-LINK] Verifying repaired link for target: {target}')
    cmd=['ninja','-C',str(build_dir),'-j1',target]
    rc,_=stream_process(cmd,env=env,log_path=log_path,phase='LINK-PREFLIGHT')
    if rc==0:
        print('[PREFLIGHT-LINK] PASS. Repaired target links successfully.')
        return True
    print('[PREFLIGHT-LINK] FAIL. Full build retry suppressed until the link repair is adjusted.')
    return False


def repair_conservative_tuning(manifest,reason):
    t=manifest.setdefault('tuning',{}); previous={k:t.get(k) for k in ('ccache','jobs','unity','lto')}
    t.update({'ccache':False,'jobs':1,'unity':False,'lto':False})
    cm=manifest.setdefault('cmake',{}); cm.pop('CMAKE_C_COMPILER_LAUNCHER',None); cm.pop('CMAKE_CXX_COMPILER_LAUNCHER',None); cm['CMAKE_INTERPROCEDURAL_OPTIMIZATION']='OFF'
    manifest.setdefault('repair_history',[]).append({'time':datetime.now(timezone.utc).isoformat(),'type':'conservative_tuning','reason':reason,'previous':previous})
    print('[AUTO-REPAIR] Conservative tuning: ccache OFF, jobs=1, unity OFF, LTO OFF.')
    return 'conservative_tuning'


def run_repair_preflight(manifest,env,log_path):
    print('[AUTO-REPAIR] Reconfiguring CMake...')
    rc,_=stream_process(build_cmd(manifest),env=env,log_path=log_path,phase='REPAIR-CMAKE')
    return rc==0 and backend_compile_preflight(manifest,env,str(log_path))


def auto_repair_and_retry(manifest,manifest_path,log_path,env,diag,max_attempts=3):
    attempts=int(manifest.get('repair_attempts',0))
    if attempts>=max_attempts:
        print(f'[AUTO-REPAIR] Repair limit ({max_attempts}) reached.')
        return False
    repair=None
    if diag.get('kind')=='link' and 'intel-sycl' in manifest.get('profile_id',''):
        if manifest.get('last_repair') == 'intel_tbb_link':
            print('[AUTO-REPAIR] TBB link repair already attempted; switching to conservative toolchain settings.')
            repair=repair_conservative_tuning(manifest,'TBB link repair did not resolve the linker failure')
        else:
            repair=repair_intel_tbb_link(manifest,env,diag) or repair_conservative_tuning(manifest,'Intel SYCL linker failure')
    elif diag.get('kind')=='compiler_crash': repair=repair_conservative_tuning(manifest,'compiler crash')
    elif diag.get('kind')=='link': repair=repair_conservative_tuning(manifest,'unclassified linker failure')
    else: return False
    manifest['repair_attempts']=attempts+1; manifest['last_repair']=repair; manifest['command']=build_cmd(manifest)
    manifest_path.write_text(json.dumps(manifest,indent=2))
    repaired_env=build_environment(manifest)
    print(f'[AUTO-REPAIR] Verification {manifest["repair_attempts"]}/{max_attempts}: {repair}')
    if not run_repair_preflight(manifest,repaired_env,log_path):
        print('[AUTO-REPAIR] Verification failed; no full retry started.')
        return False
    if diag.get('kind')=='link' and not link_target_preflight(manifest, repaired_env, diag.get('targets',[]), log_path):
        manifest.setdefault('repair_history',[]).append({
            'time':datetime.now(timezone.utc).isoformat(),
            'type':'repair_link_preflight',
            'action':'verification_failed_before_full_retry',
        })
        manifest_path.write_text(json.dumps(manifest,indent=2))
        return False
    print('[AUTO-REPAIR] Verification passed; retrying full build.')
    return True


def build_after_repair(manifest,manifest_path,log_path):
    jobs=max(1,int(manifest.get('tuning',{}).get('jobs',1)))
    buildcmd=['cmake','--build',manifest['build_dir'],'--config','Release','--parallel',str(jobs)]
    print(f'\n[BUILD] Compiling with {jobs} parallel job(s)...')
    print('$ '+' '.join(map(str,buildcmd)),flush=True)
    rc,elapsed=stream_process(buildcmd,env=build_environment(manifest),log_path=log_path,phase='COMPILE')
    manifest.setdefault('results',[]).append({'started':datetime.now(timezone.utc).isoformat(),'exit_code':rc,'elapsed_seconds':round(elapsed,1),'log':str(log_path),'repair_attempt':manifest.get('repair_attempts',0)})
    manifest_path.write_text(json.dumps(manifest,indent=2))
    return rc


def cmd_build_run(args):
    hw=scan_hardware()
    if not require_accelerator(hw): return
    if not require_dependencies(hw,interactive=False): return
    p=BUILDS/args.id/'manifest.json'
    if not p.exists(): raise SystemExit('Build not found: '+args.id)
    m=json.loads(p.read_text())
    blockers=profile_blockers({'cmake':m.get('cmake',{}),'id':m.get('profile_id')},hw)
    if blockers:
        print('\nBUILD BLOCKED before CMake configuration.')
        for b in blockers: print('  - '+b)
        return
    Path(m['build_dir']).parent.mkdir(parents=True,exist_ok=True); log_path=Path(m['build_dir']).parent/'build.log'
    env=build_environment(m)
    print('\n=== BUILD PRE-FLIGHT ===')
    print(paint('[INFO] Target, toolchain, and repair policy are shown before any compilation starts.', 'cyan'))
    print(f"Profile: {m['name']}")
    targets = m.get('target_devices') or []
    def _target_label(item):
        if isinstance(item, dict):
            return str(item.get('product') or item.get('name') or item.get('id') or '?')
        return str(item)
    target_text = ' / '.join(_target_label(x) for x in targets) or str(m.get('gpu_form_factor','unknown'))
    print(f"Target: {target_text}")
    tuning=m.get('tuning',{})
    print(f"Generator: {m.get('generator','default')}")
    print(f"Parallel jobs: {tuning.get('jobs','auto')} / detected CPU threads: {tuning.get('cpu_threads','?')}")
    print(f"ccache: {'ON' if tuning.get('ccache') else 'OFF'} | native: {'ON' if tuning.get('native',True) else 'OFF'} | unity: {'ON' if tuning.get('unity') else 'OFF'} | LTO: {'ON' if tuning.get('lto') else 'OFF'}")
    print(f"Automatic repair: ON | attempts used: {m.get('repair_attempts',0)}/3")
    print(f'Log: {log_path}')
    print('\n[1/2] Configuring CMake...')
    rc,_=stream_process(build_cmd(m),env=env,log_path=log_path,phase='CMAKE')
    if rc!=0:
        print('\nBUILD STOPPED during CMake configuration. Existing build directory preserved.'); return
    if not backend_compile_preflight(m,env,str(log_path)):
        print('\nBUILD STOPPED at backend compiler preflight. No full compilation was started.'); return
    for _ in range(4):
        rc=build_after_repair(m,p,log_path)
        if rc==0:
            print('\nBUILD COMPLETE. ✅'); return
        diag=diagnose_build_failure(m,log_path,build_environment(m))
        if not auto_repair_and_retry(m,p,log_path,build_environment(m),diag,max_attempts=3):
            print('\nBUILD STOPPED. Repair history and diagnosis are preserved.'); return
        m=json.loads(p.read_text()); print(f'[AUTO-REPAIR] Continuing with repaired manifest; attempt {m.get("repair_attempts",0)}.')

def cmd_edit(args):
    p = BUILDS / args.id / 'manifest.json'
    if not p.exists():
        raise SystemExit('Build not found: ' + args.id)
    m = json.loads(p.read_text())
    k, v = args.key.split('=', 1)
    m['cmake'][k] = v
    m['command'] = build_cmd(m)
    p.write_text(json.dumps(m, indent=2))
    print('updated', args.id)


def cmd_export(args):
    p = BUILDS / args.id / 'manifest.json'
    if not p.exists():
        raise SystemExit('Build not found: ' + args.id)
    m = json.loads(p.read_text())
    cmake_lines = ['cmake -S ' + sh_quote(m['source_dir']) + ' -B ' + sh_quote(m['build_dir'])]
    for k, v in m['cmake'].items():
        cmake_lines.append(' -D' + k + '=' + str(v))
    if m.get('generator'):
        print('# generator: ' + m['generator'])
    print('\n'.join(cmake_lines) + '\ncmake --build ' + sh_quote(m['build_dir']) + ' --config Release --parallel ' + str(m.get('tuning',{}).get('jobs',1)) + '\n')


def sh_quote(v):
    import shlex
    return shlex.quote(str(v))


def input_default(prompt, default=''):
    shown = f'{prompt} [{default}]: ' if default else f'{prompt}: '
    value = input(shown).strip()
    return value or default


def choose_index(items, label='choice'):
    while True:
        raw = input(f'{label} (number, or 0 to cancel): ').strip()
        if raw == '0':
            return None
        try:
            idx = int(raw)
            if 1 <= idx <= len(items):
                return idx - 1
        except ValueError:
            pass
        print('Please enter one of the displayed numbers.')


def print_hardware_summary(hw):
    print('\n=== HARDWARE ===')
    print(f"OS: {hw['os']['name']} | supported target: {'yes' if hw['os']['supported_target'] else 'no'}")
    print(f"Kernel: {hw['os']['kernel']} | arch: {hw['os']['arch']}")
    print(f"GPU(s): {len(hw.get('gpus', []))} | NPU(s): {len(hw.get('npus', []))} | TPU(s): {len(hw.get('tpus', []))}")
    print(f"Accelerator present: {'YES' if hw.get('accelerator_present') else 'NO'}")
    print('Capabilities: ' + ', '.join(k for k, v in hw.get('capabilities', {}).items() if v) or 'none')
    for g in hw.get('gpus', []):
        print(f"  GPU: {g.get('vendor') or ''} {g.get('product') or ''}".strip())
    for n in hw.get('npus', []):
        print(f"  NPU: {n.get('vendor') or ''} {n.get('product') or ''}".strip())
    for t in hw.get('tpus', []):
        print(f"  TPU: {t.get('vendor') or ''} {t.get('product') or ''}".strip())


def menu_generate(hw):
    if not require_accelerator(hw, interactive=True):
        input('\nPress Enter to return to the main menu...')
        return
    profiles = make_profiles(hw)
    if not profiles:
        print('\nAccelerator detected, but no supported llama.cpp profile matched it.')
        print('No CPU fallback will be generated.')
        input('\nPress Enter to return to the main menu...')
        return
    print('\n=== GENERATED BUILD PROFILES ===')
    for i, p in enumerate(profiles, 1):
        print_profile_card(i, p, hw, compact=True)
        print('   ' + ' '.join(f'{k}={v}' for k, v in p['cmake'].items()))
    print('\n1. Create all configs (do not build)')
    print('2. Create one config (do not build)')
    print('3. Create selected config and build it')
    print('0. Cancel')
    action = input('Action: ').strip().rstrip('.')
    if action == '0':
        return
    source = input_default('Path to llama.cpp source tree', selected_llama_source(hw) or os.environ.get('LLAMA_CPP_SOURCE', ''))
    if not source or not (Path(source).expanduser() / 'CMakeLists.txt').exists():
        print('That path does not appear to be a llama.cpp source tree.')
        input('Press Enter to return...')
        return
    source = str(Path(source).expanduser().resolve())
    created = []
    if action == '1':
        selected = [p for p in profiles if profile_ready(p, hw)]
        blocked = [p for p in profiles if not profile_ready(p, hw)]
        if blocked:
            print('\nBlocked profiles were not created:')
            for p in blocked:
                print(f"  - {p['name']}: {'; '.join(profile_blockers(p, hw))}")
        if not selected:
            print('No buildable profiles are currently ready. Resolve dependencies first.')
            return
    elif action in {'2', '3'}:
        idx = choose_index(profiles, 'Profile')
        if idx is None:
            return
        selected = [profiles[idx]]
        blockers = profile_blockers(selected[0], hw)
        if blockers:
            print(f"\nCannot create/build this profile yet: {'; '.join(blockers)}")
            print('Run dependency resolution, then regenerate the profiles.')
            return
    else:
        print('Unknown action.')
        return
    for p in selected:
        try:
            m = emit_build(p, hw, source)
        except RuntimeError as exc:
            print(f"Cannot create {p.get('name','profile')}: {exc}")
            continue
        created.append(m)
        print(f"Created: {m['id']}")
    if action == '3' and created:
        print('\nBuild has been explicitly requested. Starting it now.')
        cmd_build_run(argparse.Namespace(id=created[0]['id']))
    else:
        print('\nNo build was run. Configurations are ready for review or later execution.')


def menu_list():
    rows = build_rows()
    if not rows:
        print('\nNo generated builds.')
        return
    print('\n=== BUILDS ===')
    for i, x in enumerate(rows, 1):
        print(f"{i}. {x['id']} | {x['name']}")


def select_build():
    rows = build_rows()
    if not rows:
        print('No generated builds.')
        return None
    for i, x in enumerate(rows, 1):
        print(f"{i}. {x['id']} | {x['name']}")
    idx = choose_index(rows, 'Build')
    return rows[idx]['id'] if idx is not None else None


def interactive_menu():
    hw = scan_hardware()
    while True:
        source = selected_llama_source(hw)
        print('\n' + '=' * 72)
        print(' LLAMA.CPP BUILD FORGE')
        print('=' * 72)
        print(' Accelerator-first hardware-aware build manager')
        print(' CPU fallback: DISABLED')
        print('')
        print(f"System: {hw['os']['name']} | accelerator: {'YES' if hw.get('accelerator_present') else 'NO'}")
        print(f"GPU {len(hw.get('gpus', []))} | NPU {len(hw.get('npus', []))} | TPU {len(hw.get('tpus', []))}")
        print(f"llama.cpp: {source if source else 'NOT FOUND'}")
        print('')
        print(' 1. Scan hardware')
        print(' 2. Check/install dependencies (live scan)')
        print(' 3. Generate build configurations')
        print(' 4. Build manager (list + details + actions)')
        print(' 5. Configure/edit a build (checkbox editor)')
        print(' 6. Build a configuration')
        print(' 7. Delete a build')
        print(' 8. Export build commands')
        print(' 9. Refresh switch catalogue')
        print('10. Show switch catalogue')
        print('11. Tune build performance (shows CPU/RAM/jobs)')
        print(' 0. Exit')
        try:
            choice = normalise_menu_choice(input('\nSelect an option: '))
        except KeyboardInterrupt:
            print('\nCancelled. Returning to the menu.')
            continue
        except EOFError:
            print('\nEnd of input. Exiting.')
            return
        if choice == '0':
            print('Goodbye.')
            return
        if choice == '1':
            hw = scan_hardware(); print_hardware_summary(hw); input('\nPress Enter to continue...')
        elif choice == '2':
            install_missing_dependencies(hw); input('\nPress Enter to continue...'); hw = scan_hardware()
        elif choice == '3':
            menu_generate(hw); hw = scan_hardware()
        elif choice == '4':
            rows=build_rows()
            if not rows:
                unified_build_view(rows); input('\nPress Enter to continue...'); continue
            idx=choose_index(rows,'Build')
            if idx is not None:
                unified_build_view(rows, idx)
                print('\nActions: [b] build  [e] edit  [d] delete  [x] export  [r] return')
                action=normalise_menu_choice(safe_input('Action: ')).lower()
                bid=rows[idx]['id']
                if action=='b':
                    if safe_input(f"Build '{bid}' now? [y/N]: ").strip().lower()=='y': cmd_build_run(argparse.Namespace(id=bid))
                elif action=='e': edit_build_interactive(rows[idx])
                elif action=='d' and safe_input(f"Delete '{bid}'? [y/N]: ").strip().lower()=='y': cmd_delete(argparse.Namespace(id=bid))
                elif action=='x': cmd_export(argparse.Namespace(id=bid))
            input('\nPress Enter to continue...')
        elif choice == '5':
            rows=build_rows()
            if not rows:
                unified_build_view(rows)
                input('\nPress Enter to continue...')
                continue
            # Reuse the same build table/details presentation as option 4 so
            # the user never has to guess what number they are editing.
            unified_build_view(rows)
            idx=choose_index(rows,'Build to configure')
            if idx is not None:
                unified_build_view(rows, idx)
                edit_build_interactive(rows[idx])
            input('\nPress Enter to continue...')
        elif choice == '6':
            if not require_accelerator(hw, interactive=True): input('\nPress Enter to continue...'); continue
            bid=select_build()
            if bid:
                if safe_input(f"Build '{bid}' now? [y/N]: ").strip().lower()=='y':
                    cmd_build_run(argparse.Namespace(id=bid))
                else: print('Build cancelled. Nothing was built.')
            input('\nPress Enter to continue...')
        elif choice == '7':
            bid=select_build()
            if bid and safe_input(f"Delete '{bid}'? [y/N]: ").strip().lower()=='y': cmd_delete(argparse.Namespace(id=bid))
            input('\nPress Enter to continue...')
        elif choice == '8':
            bid=select_build()
            if bid: cmd_export(argparse.Namespace(id=bid))
            input('\nPress Enter to continue...')
        elif choice == '9':
            refresh=ROOT/'bin'/'refresh-switches'; subprocess.run([str(refresh)], check=False); input('\nPress Enter to continue...')
        elif choice == '10':
            catalogue=load_catalogue(); print('\n=== SWITCH CATALOGUE ===')
            for item in catalogue:
                print(f"\n{item.get('name',item.get('key'))}: {item.get('description','')}")
                if item.get('examples'): print('  Example: '+item['examples'][0])
            input('\nPress Enter to continue...')
        elif choice == '11':
            apply_perf_to_all(); input('\nPress Enter to continue...')
        else:
            print('Unknown option. Please choose a displayed number.')

def main():
    ap = argparse.ArgumentParser(prog='llama-forge', description='Hardware-aware accelerator-first llama.cpp build profile generator')
    sub = ap.add_subparsers(dest='cmd', required=False)
    p = sub.add_parser('scan'); p.set_defaults(fn=cmd_scan)
    p = sub.add_parser('dependencies'); p.set_defaults(fn=lambda args: install_missing_dependencies(scan_hardware()))
    p = sub.add_parser('generate'); p.add_argument('--source', help='Path to llama.cpp checkout; generate build folders now'); p.set_defaults(fn=cmd_generate)
    p = sub.add_parser('list'); p.set_defaults(fn=cmd_list)
    p = sub.add_parser('show'); p.add_argument('id'); p.set_defaults(fn=cmd_show)
    p = sub.add_parser('delete'); p.add_argument('id'); p.set_defaults(fn=cmd_delete)
    p = sub.add_parser('edit'); p.add_argument('id'); p.add_argument('key'); p.set_defaults(fn=cmd_edit)
    p = sub.add_parser('build-run'); p.add_argument('id'); p.set_defaults(fn=cmd_build_run)
    p = sub.add_parser('export'); p.add_argument('id'); p.set_defaults(fn=cmd_export)
    p = sub.add_parser('performance'); p.set_defaults(fn=lambda args: apply_perf_to_all())
    # Module-facing aliases: these open the relevant interactive Forge panels.
    p = sub.add_parser('manager'); p.set_defaults(fn=lambda args: interactive_menu())
    p = sub.add_parser('configure'); p.set_defaults(fn=lambda args: interactive_menu())
    p = sub.add_parser('catalogue'); p.set_defaults(fn=lambda args: interactive_menu())
    p = sub.add_parser('repair'); p.set_defaults(fn=lambda args: interactive_menu())
    args = ap.parse_args()
    if not args.cmd:
        interactive_menu()
    else:
        args.fn(args)

if __name__ == '__main__':
    main()
