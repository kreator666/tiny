# 运维手册 · 新宋 · 治所

Windows + Godot 4.7.2 项目的日常运维命令。所有命令在项目根目录（`d:\agent\tiny`）下执行。

## 环境

- Godot 安装路径（WinGet）：
  `C:\Users\tiger\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\`
  - 编辑器 / 游戏运行：`Godot_v4.7.2-stable_win64.exe`
  - 命令行（带日志输出）：`Godot_v4.7.2-stable_win64_console.exe`
- 导出模板已安装于 `%APPDATA%\Godot\export_templates\4.7.2.stable\`（缺失时导出脚本会自动下载）

下文用 `$GODOT` 代指 console 版 exe 的绝对路径。

## 打包发布（最常用）

双击运行，或在 cmd 中执行：

```
tools\export_windows.bat
```

等价的手动命令（Git Bash）：

```bash
"$GODOT" --headless --path /d/agent/tiny --export-release "Windows Desktop" "build/xinsong-zhisuo.exe"
```

产物（两者必须放在一起分发）：

- `build/xinsong-zhisuo.exe`（约 105MB，含引擎）
- `build/xinsong-zhisuo.pck`（资源包）

注意：exe 未做代码签名，Windows SmartScreen 会提示"未知发布者"，点"仍要运行"即可。
`build/` 已在 `.gitignore` 中，不会进 git。

## 运行游戏（编辑器外调试）

```bash
"/c/Users/tiger/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64.exe" --path /d/agent/tiny
```

日志重定向到文件方便排错：

```bash
"$GODOT" --path /d/agent/tiny > "$LOCALAPPDATA/Temp/godot_run.log" 2>&1
```

## 自动化测试

回归测试脚本位于本机 `%LOCALAPPDATA%\Temp\test_*.gd`（不进仓库），运行方式：

```bash
"$GODOT" --headless --path /d/agent/tiny -s "$LOCALAPPDATA/Temp/test_evolve.gd"
```

现有回归：`test_evolve`（住房演进）、`test_buildings`（建筑）、`test_save_slots`（存档）、`test_roads`（道路变体）、`test_clinic_repair`（医馆/维修站）。

写新测试脚本的约定：

- `extends SceneTree`，`func _initialize(): call_deferred("_run")`，结尾必须 `quit()`
- 取当前场景用 `current_scene`（`-s` 模式下根节点下标不可靠）
- GDScript 4.7 陷阱：`var x := 从 Variant 取值` 会报类型推断错，改用显式类型或 `var x = ...`

## AI 素材生成

```bash
python tools/gen_ai_assets.py <素材包名>            # 生成包内全部素材
python tools/gen_ai_assets.py <素材包名> <素材名>   # 只生成指定素材（调试用）
python tools/gen_ai_assets.py --test                # 试生成一张到临时目录，不入库
```

- 提供商与 key 配置在 `tools/ai_provider.json`（302.ai / aiping.cn 可切换）
- key 文件 `tools/*_api_key.txt` 已被 gitignore
- 素材包架构：按包名分目录，替换素材 = 换目录，无需改代码
- 新生成的 PNG 首次使用前要导入一次：

```bash
"$GODOT" --headless --path /d/agent/tiny --import
```
