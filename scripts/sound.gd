class_name Sound
extends RefCounted
## 程序合成音效：不依赖任何音频素材，运行时生成 16-bit 单声道 PCM。
## 用法：Sound.play("build")；可用名称：
##   click(选工具) build(建造) demolish(拆除) coin(嘉奖/收钱)
##   warn(失败/警告) evolve(住房升级)

const RATE := 22050

static var _player: AudioStreamPlayer
static var _streams: Dictionary = {}


static func play(name: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	if _player == null:
		_player = AudioStreamPlayer.new()
		_player.volume_db = -8.0
		tree.root.add_child(_player)
		_build_all()
	var stream: AudioStreamWAV = _streams.get(name)
	if stream == null:
		return
	_player.stream = stream
	_player.play()


# ---------- 合成 ----------

static func _build_all() -> void:
	_streams["click"] = _wav([_seg(880.0, 0.06)])
	_streams["build"] = _wav([_seg(330.0, 0.08), _seg(520.0, 0.14)])
	_streams["demolish"] = _wav([_seg(180.0, 0.10, 0.8, true), _seg(120.0, 0.16, 0.6, true)])
	_streams["coin"] = _wav([_seg(1318.0, 0.06), _seg(1760.0, 0.12)])
	_streams["warn"] = _wav([_seg(233.0, 0.12), _seg(196.0, 0.20)])
	_streams["evolve"] = _wav([_seg(523.0, 0.09), _seg(659.0, 0.09), _seg(784.0, 0.16)])


static func _seg(freq: float, dur: float, vol := 1.0, noise := false) -> Dictionary:
	return {"freq": freq, "dur": dur, "vol": vol, "noise": noise}


static func _wav(segments: Array) -> AudioStreamWAV:
	var total := 0
	for seg: Dictionary in segments:
		total += int(float(seg["dur"]) * RATE)
	var bytes := PackedByteArray()
	bytes.resize(total * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234567
	var offset := 0
	for seg: Dictionary in segments:
		var n := int(float(seg["dur"]) * RATE)
		var freq := float(seg["freq"])
		var vol := float(seg["vol"])
		var use_noise := bool(seg["noise"])
		for i in n:
			var t := float(i) / RATE
			var env := exp(-3.5 * t / float(seg["dur"]))
			var sample := 0.0
			if use_noise:
				sample = (rng.randf() * 2.0 - 1.0) * 0.6 + sin(TAU * freq * t) * 0.4
			else:
				sample = sin(TAU * freq * t)
			var v := int(clampf(sample * env * vol, -1.0, 1.0) * 32767.0)
			bytes.encode_s16(offset + i * 2, v)
		offset += n * 2

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.data = bytes
	return stream
