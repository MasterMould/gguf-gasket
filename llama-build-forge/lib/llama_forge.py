#!/usr/bin/env python3
import argparse, json, os, platform, re, shutil, subprocess, sys, textwrap, time
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


def which_version(name):
    path = shutil.which(name)
    if not path:
        return None
    out, err, rc = run([path, '--version'], 8)
    version = (out or err).splitlines()[0] if (out or err) else ''
    return {'path': path, 'version': version}


def find_llama_cpp():
    found = []
    seen = set()
    candidates = []
    env = os.environ.get('LLAMA_CPP_SOURCE', '')
    if env:
        candidates.append(Path(env).expanduser())
    for base in [Path.home(), Path('/opt'), Path('/usr/local/src'), Path('/usr/src'), Path('/workspace')]:
        candidates.append(base)
    # Explicitly search shallowly and inspect likely names. Avoid an expensive full filesystem crawl.
    for base in candidates:
        if not base.exists():
            continue
        if (base / 'CMakeLists.txt').exists() and (base / 'ggml').exists():
            candidates.append(base)
        try:
            for p in base.glob('**/llama.cpp'):
                if p.is_dir():
                    candidates.append(p)
        except Exception:
            pass
    for p in candidates:
        try:
            rp = p.resolve()
        except Exception:
            continue
        key = str(rp)
        if key in seen or not rp.is_dir():
            continue
        if (rp / 'CMakeLists.txt').exists() and (rp / 'ggml').is_dir():
            seen.add(key)
            found.append({'type': 'source', 'path': key, 'git': str((rp / '.git').exists())})
    for name in ['llama-cli', 'llama-server', 'llama-bench', 'llama-run']:
        info = which_version(name)
        if info:
            found.append({'type': 'binary', 'name': name, **info})
    # Common local build output locations.
    for base in [Path.home() / 'llama.cpp/build/bin', Path('/usr/local/bin')]:
        for name in ['llama-cli', 'llama-server', 'llama-bench']:
            f = base / name
            if f.is_file() and os.access(f, os.X_OK):
                found.append({'type': 'binary', 'name': name, 'path': str(f)})
    return found


def apt_cache_available(pkg):
    out, err, rc = run(['apt-cache', 'policy', pkg], 10)
    if rc != 0:
        return False
    return bool(re.search(r'Candidate:\s+(?!\(none\))\S+', out))


def dependency_inventory(hw):
    deps = load_dependencies()
    tools = hw.get('tools', {})
    checks = {
        'base': all(tools.get(x) for x in ['cmake', 'git', 'gcc', 'g++', 'pkg-config']),
        'vulkan': all(tools.get(x) for x in ['vulkaninfo']) and Path('/usr/include/vulkan').exists(),
        'opencl': bool(tools.get('clinfo')),
        'cuda': bool(tools.get('nvcc')) and bool(tools.get('nvidia-smi')),
        'rocm': bool(tools.get('hipcc')) and bool(tools.get('rocminfo')),
        'sycl': bool(tools.get('icpx')) and bool(tools.get('sycl-ls')),
    }
    # Driver/runtime presence is separate from compiler/toolkit presence.
    checks['intel_driver'] = Path('/usr/lib/x86_64-linux-gnu/libze_loader.so').exists() or Path('/dev/dri').exists()
    checks['amd_driver'] = Path('/dev/kfd').exists() or bool(tools.get('rocminfo'))
    checks['nvidia_driver'] = bool(tools.get('nvidia-smi'))
    return {
        'llama_cpp': find_llama_cpp(),
        'checks': checks,
        'packages': deps.get('ubuntu', {}).get(hw['os']['version_id'], {}),
        'manual': deps.get('manual', {}),
    }


def dependency_status(hw):
    inv = dependency_inventory(hw)
    required = ['base']
    gpu_text = ' '.join(json.dumps(g).lower() for g in hw.get('gpus', []))
    caps = hw.get('capabilities', {})
    # Hardware family drives the required toolchain, not whether the toolchain
    # happens to be installed. This is what lets the menu explain missing
    # software before CMake fails.
    if 'nvidia' in gpu_text:
        required.append('cuda')
    if 'amd' in gpu_text or 'radeon' in gpu_text:
        required.append('rocm')
    if 'intel' in gpu_text:
        required.append('sycl')
    if caps.get('vulkan'):
        required.append('vulkan')
    if caps.get('opencl'):
        required.append('opencl')
    required = list(dict.fromkeys(required))
    missing = [x for x in required if not inv['checks'].get(x)]
    return inv, missing


def install_missing_dependencies(hw):
    inv, missing = dependency_status(hw)
    print('\n=== DEPENDENCY STATUS ===')
    print('llama.cpp installations found:')
    for x in inv['llama_cpp']:
        print('  ' + json.dumps(x, sort_keys=True))
    if not inv['llama_cpp']:
        print('  none found')
    print('\nBackend prerequisites:')
    for k, v in inv['checks'].items():
        print(f'  {k:15} ' + ('OK' if v else 'MISSING'))
    if not missing:
        print('\nAll detected prerequisites are present.')
        return
    print('\nMissing required components: ' + ', '.join(missing))
    if hw['os']['id'] != 'ubuntu' or hw['os']['version_id'] not in {'24.04','26.04'}:
        print('Automatic package installation is limited to Ubuntu 24.04/26.04.')
        return
    packages=[]
    for group in missing:
        packages.extend(inv['packages'].get(group, []))
    packages=[x for x in dict.fromkeys(packages) if apt_cache_available(x)]
    if packages:
        print('\nAPT packages available in configured repositories:')
        for x in packages: print('  ' + x)
        answer=input('Install these packages now with sudo apt-get? [y/N]: ').strip().lower()
        if answer=='y':
            subprocess.run(['sudo','apt-get','update'], check=False)
            subprocess.run(['sudo','apt-get','install','-y',*packages], check=False)
    for group in missing:
        if not inv['packages'].get(group) or not any(apt_cache_available(x) for x in inv['packages'].get(group, [])):
            manual=inv['manual'].get(group)
            if manual:
                print(f"\n{manual['label']}: {manual['note']}")
                print('Automatic installation is not attempted for this vendor stack.')

def require_dependencies(hw, interactive=False):
    inv, missing = dependency_status(hw)
    if not missing:
        return True
    print('\nBUILD PREREQUISITES MISSING: ' + ', '.join(missing))
    print('Run the dependency manager to install or configure the missing components before building.')
    if interactive:
        ans = input('Open dependency manager now? [Y/n]: ').strip().lower()
        if ans in {'', 'y', 'yes'}:
            install_missing_dependencies(hw)
            inv, missing = dependency_status(scan_hardware())
    if missing:
        print('Build blocked. No compilation was started.')
        return False
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
        if cls == 'display' or 'graphics' in desc.lower() or any(x in blob for x in ['gpu', 'vga compatible controller', '3d controller']):
            gpus.append({k: d.get(k) for k in ['id','product','vendor','version','width','clock','size','configuration','businfo','physid']})
        if cls == 'processor':
            cpus.append({k: d.get(k) for k in ['id','product','vendor','version','width','clock']})
        if cls == 'network':
            nics.append({k: d.get(k) for k in ['id','product','vendor','logicalname','configuration']})
        if any(x in blob for x in ['neural processing unit', ' npu', 'npu ', 'neural accelerator']):
            npus.append({k: d.get(k) for k in ['id','product','vendor','version','configuration','businfo']})
        if any(x in blob for x in ['tensor processing unit', ' tpu', 'tpu ', 'coral']) or 'google edge tpu' in blob:
            tpus.append({k: d.get(k) for k in ['id','product','vendor','version','configuration','businfo']})

    tools = commands_present([
        'cmake','ninja','gcc','g++','clang','clang++','icx','icpx','hipcc','nvcc',
        'vulkaninfo','clinfo','sycl-ls','xpu-smi','rocminfo','nvidia-smi','glxinfo',
        'ccache','sccache','git','lspci','lshw'
    ])
    drivers = {
        'cuda': bool(tools.get('nvcc')) or bool(re.search(r'VGA compatible controller: NVIDIA|3D controller: NVIDIA', pci, re.I)),
        'amd': bool(tools.get('hipcc')) or bool(re.search(r'VGA compatible controller: (Advanced Micro Devices|AMD)|3D controller: (Advanced Micro Devices|AMD)', pci, re.I)),
        'intel': bool(tools.get('icx')) or bool(re.search(r'VGA compatible controller: Intel|3D controller: Intel', pci, re.I)),
        'vulkan': bool(tools.get('vulkaninfo')),
        'opencl': bool(tools.get('clinfo')),
        'sycl': bool(tools.get('sycl-ls')) or bool(tools.get('icpx')),
        'rocm': bool(tools.get('rocminfo')) or bool(tools.get('hipcc')),
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


def load_catalog():
    return json.loads((DATA / 'build_switches.json').read_text())


def str_contains(items, patterns):
    text = ' '.join(str(x or '') for x in items).lower()
    return any(p.lower() in text for p in patterns)


def gpu_form_factor(hw):
    result = []
    for g in hw.get('gpus', []):
        blob = json.dumps(g).lower()
        discrete = bool(g.get('businfo')) or bool(g.get('physid'))
        if any(x in blob for x in ['uhd graphics','iris','radeon graphics','vega graphics','apu']):
            discrete = False
        result.append({'product': g.get('product'), 'vendor': g.get('vendor'), 'discrete': discrete})
    if any(x['discrete'] for x in result):
        return 'discrete'
    if result:
        return 'integrated'
    return 'unknown'


def target_name(hw):
    gpu_text = ' '.join(json.dumps(g).lower() for g in hw.get('gpus', []))
    caps = hw.get('capabilities', {})
    if caps.get('cuda') or 'nvidia' in gpu_text:
        return 'nvidia-cuda'
    if caps.get('rocm') or caps.get('amd') or str_contains([gpu_text], ['amd','radeon']):
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

    if caps.get('rocm') or caps.get('amd') or 'amd' in gpu_text or 'radeon' in gpu_text:
        p = base(f'AMD HIP / ROCm ({form})', 'amd-hip', 'ROCm/HIP acceleration for AMD GPUs.', 100)
        p['cmake'].update({'GGML_HIP': 'ON', 'GGML_NATIVE': 'ON', 'GGML_HIP_GRAPHS': 'ON', 'CMAKE_C_COMPILER': 'clang', 'CMAKE_CXX_COMPILER': 'clang++'})
        p['environment'] = {}
        hipcc = shutil.which('hipcc')
        if hipcc:
            hp = run([hipcc, '-R'], 8)[0].strip()
            if hp:
                p['environment']['HIP_PATH'] = hp
                p['environment']['HIPCXX'] = str(Path(hp) / 'bin' / 'clang')
        profiles.append(p)
        if caps.get('vulkan'):
            v = base('AMD Vulkan Fallback', 'amd-vulkan', 'Vulkan alternative when ROCm is absent, problematic, or intentionally avoided.', 70)
            v['cmake'].update({'GGML_VULKAN': 'ON', 'GGML_NATIVE': 'ON'})
            profiles.append(v)

    if caps.get('intel') or 'intel' in gpu_text:
        if caps.get('sycl'):
            p = base(f'Intel SYCL / oneAPI ({form})', 'intel-sycl', 'Intel GPU acceleration through SYCL and Level Zero.', 100)
            p['cmake'].update({'GGML_SYCL': 'ON', 'GGML_SYCL_TARGET': 'INTEL', 'GGML_SYCL_SUPPORT_LEVEL_ZERO': 'ON', 'GGML_NATIVE': 'ON', 'CMAKE_C_COMPILER': 'icx', 'CMAKE_CXX_COMPILER': 'icpx'})
            p['environment'] = {}
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

    if 'amd' in gpu_text and caps.get('vulkan') and caps.get('rocm'):
        profiles.append({'id': 'amd-dual-hip-vulkan', 'name': 'AMD HIP + Vulkan', 'score': 82,
                         'notes': 'Build both backends; runtime can choose the appropriate device.',
                         'cmake': {'CMAKE_BUILD_TYPE': 'Release', 'GGML_HIP': 'ON', 'GGML_VULKAN': 'ON', 'GGML_NATIVE': 'ON', 'CMAKE_C_COMPILER': 'clang', 'CMAKE_CXX_COMPILER': 'clang++'},
                         'environment': {}})
    if ('intel' in gpu_text or caps.get('intel')) and caps.get('vulkan') and caps.get('sycl'):
        profiles.append({'id': 'intel-dual-sycl-vulkan', 'name': 'Intel SYCL + Vulkan', 'score': 86,
                         'notes': 'Build both Intel GPU backends; useful for fallback and A/B testing.',
                         'cmake': {'CMAKE_BUILD_TYPE': 'Release', 'GGML_SYCL': 'ON', 'GGML_SYCL_TARGET': 'INTEL', 'GGML_SYCL_SUPPORT_LEVEL_ZERO': 'ON', 'GGML_VULKAN': 'ON', 'GGML_NATIVE': 'ON', 'CMAKE_C_COMPILER': 'icx', 'CMAKE_CXX_COMPILER': 'icpx'},
                         'environment': {}})
    return sorted(profiles, key=lambda x: (-x['score'], x['id']))


def build_environment(manifest):
    env = os.environ.copy()
    for k, v in manifest.get('environment', {}).items():
        if v:
            env[k] = str(v)
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
        print('You can still inspect hardware, the switch catalog, and existing build folders.')
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


def recommended_build_tuning():
    r = system_resources()
    jobs = max(1, r['cpu_threads'])
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


def configure_performance(m, level=None):
    levels = {
        '1': ('Balanced', {'generator': 'Ninja', 'jobs': recommended_build_tuning()['jobs'], 'ccache': bool(shutil.which('ccache')), 'native': True, 'unity': False, 'lto': False}),
        '2': ('Fast compile', {'generator': 'Ninja', 'jobs': recommended_build_tuning()['jobs'], 'ccache': True, 'native': True, 'unity': True, 'unity_batch_size': 8, 'lto': False}),
        '3': ('Maximum runtime optimization', {'generator': 'Ninja', 'jobs': recommended_build_tuning()['jobs'], 'ccache': True, 'native': True, 'unity': False, 'lto': True}),
        '4': ('Conservative / compatibility', {'generator': 'Unix Makefiles', 'jobs': min(4, recommended_build_tuning()['jobs']), 'ccache': bool(shutil.which('ccache')), 'native': False, 'unity': False, 'lto': False}),
    }
    if level not in levels:
        return None
    return levels[level]


def apply_perf_to_all():
    rows = build_rows()
    if not rows:
        print('\nNo generated builds.')
        return
    print('\n=== PERFORMANCE PROFILES ===')
    print('1. Balanced: Ninja + parallel jobs + native CPU tuning + ccache when installed')
    print('2. Fast compile: Balanced + CMake unity builds')
    print('3. Maximum runtime optimization: Balanced + LTO/IPO')
    print('4. Conservative: portable CPU flags and fewer parallel jobs')
    level = input('Profile (0 to cancel): ').strip()
    if level == '0':
        return
    result = configure_performance(level)
    if not result:
        print('Invalid profile.')
        return
    name, cfg = result
    changed = 0
    for m in rows:
        build_root = Path(m['build_dir'])
        if build_root.exists() and (build_root / 'CMakeCache.txt').exists():
            backup = build_root.parent / ('cmake.previous-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
            try:
                build_root.rename(backup)
                print(f"Preserved previous CMake tree: {backup}")
            except OSError as e:
                print(f"Could not preserve existing CMake tree for {m['id']}: {e}")
                print('Skipping this build to avoid generator/cache mismatch.')
                continue
        apply_tuning_to_manifest(m, cfg)
        m['dependency_contract'] = dependency_contract(m['hardware'], {
            'id': m.get('profile_id', 'custom'),
            'cmake': m.get('cmake', {})
        }, m['tuning'])
        m['command'] = build_cmd(m)
        p = BUILDS / m['id'] / 'manifest.json'
        p.write_text(json.dumps(m, indent=2))
        changed += 1
    print(f'Applied {name} tuning to {changed}/{len(rows)} build(s).')
    if not cfg.get('ccache'):
        print('Note: ccache is not installed, so repeated-build caching is unavailable.')
    print('The next build will perform a fresh CMake configure with the selected tuning.')


def cmd_scan(_):
    print(json.dumps(scan_hardware(), indent=2))


def cmd_generate(args):
    hw = scan_hardware()
    if not require_accelerator(hw):
        return
    if not hw['os']['supported_target']:
        print(f"WARNING: detected {hw['os']['name']}; generator is currently targeted at Ubuntu 24.04/26.04.", file=sys.stderr)
    inv, missing = dependency_status(hw)
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


def cmd_build_run(args):
    hw = scan_hardware()
    if not require_accelerator(hw):
        return
    if not require_dependencies(hw, interactive=False):
        return
    p = BUILDS / args.id / 'manifest.json'
    if not p.exists():
        raise SystemExit('Build not found: ' + args.id)
    m = json.loads(p.read_text())
    Path(m['build_dir']).parent.mkdir(parents=True, exist_ok=True)
    log_path = Path(m['build_dir']).parent / 'build.log'
    print('\n=== BUILD PRE-FLIGHT ===')
    print(f"Profile: {m['name']}")
    print(f"Generator: {m.get('generator','default')}")
    print(f"Parallel jobs: {m.get('tuning',{}).get('jobs','auto')}")
    print(f"ccache: {'ON' if m.get('tuning',{}).get('ccache') else 'OFF'} | native: {'ON' if m.get('tuning',{}).get('native',True) else 'OFF'} | unity: {'ON' if m.get('tuning',{}).get('unity') else 'OFF'} | LTO: {'ON' if m.get('tuning',{}).get('lto') else 'OFF'}")
    print(f'Log: {log_path}')
    print('\n[1/2] Configuring CMake...')
    cmd = build_cmd(m)
    print('$ ' + ' '.join(map(str, cmd)), flush=True)
    rc, _ = stream_process(cmd, env=build_environment(m), log_path=log_path, phase='CMAKE')
    if rc != 0:
        print('\nBUILD STOPPED during CMake configuration. Existing build directory preserved.')
        return
    jobs = max(1, int(m.get('tuning', {}).get('jobs', 1)))
    buildcmd = ['cmake', '--build', m['build_dir'], '--config', 'Release', '--parallel', str(jobs)]
    print(f'\n[2/2] Compiling with {jobs} parallel job(s)...')
    print('$ ' + ' '.join(map(str, buildcmd)), flush=True)
    rc, elapsed = stream_process(buildcmd, env=build_environment(m), log_path=log_path, phase='COMPILE')
    m.setdefault('results', []).append({'started': datetime.now(timezone.utc).isoformat(), 'exit_code': rc, 'elapsed_seconds': round(elapsed,1), 'log': str(log_path)})
    p.write_text(json.dumps(m, indent=2))
    if rc != 0:
        print('\nBUILD FAILED. The build directory and build.log were preserved for diagnosis.')
        print('Use the Performance Tuning option to try a different compilation strategy.')
        return
    print('\nBUILD COMPLETE. ✅')


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
        print(f"{i}. {p['name']}  [score {p['score']}]")
        print(f"   {p['notes']}")
        print('   ' + ' '.join(f'{k}={v}' for k, v in p['cmake'].items()))
    print('\n1. Create all configs (do not build)')
    print('2. Create one config (do not build)')
    print('3. Create selected config and build it')
    print('0. Cancel')
    action = input('Action: ').strip()
    if action == '0':
        return
    source = input_default('Path to llama.cpp source tree', os.environ.get('LLAMA_CPP_SOURCE', ''))
    if not source or not (Path(source).expanduser() / 'CMakeLists.txt').exists():
        print('That path does not appear to be a llama.cpp source tree.')
        input('Press Enter to return...')
        return
    source = str(Path(source).expanduser().resolve())
    created = []
    if action == '1':
        selected = profiles
    elif action in {'2', '3'}:
        idx = choose_index(profiles, 'Profile')
        if idx is None:
            return
        selected = [profiles[idx]]
    else:
        print('Unknown action.')
        return
    for p in selected:
        m = emit_build(p, hw, source)
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
        print('\n' + '=' * 64)
        print(' LLAMA.CPP BUILD FORGE')
        print('=' * 64)
        print(' Accelerator-first hardware-aware build manager')
        print(' CPU fallback: DISABLED')
        print('')
        print(f"System: {hw['os']['name']} | accelerator: {'YES' if hw.get('accelerator_present') else 'NO'}")
        print(f"GPU {len(hw.get('gpus', []))} | NPU {len(hw.get('npus', []))} | TPU {len(hw.get('tpus', []))}")
        print('')
        print(' 1. Scan hardware')
        print(' 2. Check/install dependencies')
        print(' 3. Generate build configurations')
        print(' 4. List builds')
        print(' 5. View build details')
        print(' 6. Edit build CMake option')
        print(' 7. Build a configuration')
        print(' 8. Delete a build')
        print(' 9. Export build commands')
        print('10. Refresh switch catalog')
        print('11. Show switch catalog')
        print('12. Improve build performance')
        print(' 0. Exit')
        choice = input('\nSelect an option: ').strip()
        if choice == '0':
            print('Goodbye.')
            return
        if choice == '1':
            hw = scan_hardware()
            print_hardware_summary(hw)
            input('\nPress Enter to continue...')
        elif choice == '2':
            install_missing_dependencies(hw)
            input('\nPress Enter to continue...')
            hw = scan_hardware()
        elif choice == '3':
            menu_generate(hw)
            hw = scan_hardware()
        elif choice == '4':
            menu_list(); input('\nPress Enter to continue...')
        elif choice == '5':
            bid = select_build()
            if bid:
                cmd_show(argparse.Namespace(id=bid)); input('\nPress Enter to continue...')
        elif choice == '6':
            bid = select_build()
            if bid:
                key = input('CMake assignment, e.g. GGML_CUDA_GRAPHS=OFF: ').strip()
                if '=' in key and key.split('=',1)[0].strip() and key.split('=',1)[1].strip():
                    cmd_edit(argparse.Namespace(id=bid, key=key))
                else:
                    print('Invalid assignment. Use KEY=VALUE.')
                input('\nPress Enter to continue...')
        elif choice == '7':
            if not require_accelerator(hw, interactive=True):
                input('\nPress Enter to continue...')
                continue
            if not require_dependencies(hw, interactive=True):
                input('\nPress Enter to continue...')
                continue
            bid = select_build()
            if bid:
                confirm = input(f"Build '{bid}' now? [y/N]: ").strip().lower()
                if confirm == 'y':
                    try:
                        cmd_build_run(argparse.Namespace(id=bid))
                    except subprocess.CalledProcessError as e:
                        print(f'\nBUILD FAILED (exit {e.returncode}). The failed build directory was preserved for inspection.')
                    except Exception as e:
                        print(f'\nBUILD FAILED: {e}')
                else:
                    print('Build cancelled. Nothing was built.')
                input('\nPress Enter to continue...')
        elif choice == '8':
            bid = select_build()
            if bid:
                confirm = input(f"Delete '{bid}'? [y/N]: ").strip().lower()
                if confirm == 'y':
                    cmd_delete(argparse.Namespace(id=bid))
                else:
                    print('Delete cancelled.')
                input('\nPress Enter to continue...')
        elif choice == '9':
            bid = select_build()
            if bid:
                cmd_export(argparse.Namespace(id=bid)); input('\nPress Enter to continue...')
        elif choice == '10':
            refresh = ROOT / 'bin' / 'refresh-switches'
            subprocess.run([str(refresh)], check=False)
            input('\nPress Enter to continue...')
        elif choice == '11':
            catalog = load_catalog()
            print('\n=== SWITCH CATALOG ===')
            for item in catalog:
                print(f"\n{item.get('name', item.get('key'))}: {item.get('description', '')}")
                if item.get('examples'):
                    print('  Example: ' + item['examples'][0])
            input('\nPress Enter to continue...')
        elif choice == '12':
            apply_perf_to_all()
            input('\nPress Enter to continue...')
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
    args = ap.parse_args()
    if not args.cmd:
        interactive_menu()
    else:
        args.fn(args)

if __name__ == '__main__':
    main()
