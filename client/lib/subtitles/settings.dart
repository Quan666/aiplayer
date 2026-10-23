import 'package:flutter/material.dart';
import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../ui/glass.dart';
import 'ai.dart';

class AiSubtitleSettings extends StatefulWidget {
  final AppModel model;
  final SubtitleAiTransport? transport;
  const AiSubtitleSettings({super.key, required this.model, this.transport});
  @override
  State<AiSubtitleSettings> createState() => _AiSubtitleSettingsState();
}

class _AiSubtitleSettingsState extends State<AiSubtitleSettings> {
  final origin = TextEditingController(),
      token = TextEditingController(),
      modelName = TextEditingController(),
      target = TextEditingController(),
      prompt = TextEditingController();
  bool loading = true, saving = false, loadingModels = false, reveal = false;
  String result = '';
  List<String> models = [];
  CancelToken? _cancel;
  @override
  void initState() {
    super.initState();
    final settings = widget.model.settings;
    origin.text =
        '${settings['aiSubtitleOrigin'] ?? 'https://api.openai.com/v1'}';
    modelName.text = '${settings['aiSubtitleModel'] ?? ''}';
    target.text = '${settings['aiSubtitleTarget'] ?? '简体中文'}';
    prompt.text = '${settings['aiSubtitlePrompt'] ?? ''}';
    origin.addListener(_providerChanged);
    token.addListener(_providerChanged);
    _load();
  }

  void _providerChanged() {
    _cancel?.cancel();
    _cancel = null;
    if (!mounted) return;
    setState(() {
      models = [];
      loadingModels = false;
      result = '';
    });
  }

  Future<void> _load() async {
    try {
      final secret = await widget.model.secrets.read(key: 'aiSubtitleToken');
      AppLog.instance.rememberSecret(secret);
      if (mounted) token.text = secret ?? '';
    } catch (_) {
      if (mounted) result = '无法读取系统安全存储，请检查系统密钥服务。';
    }
    if (mounted) setState(() => loading = false);
  }

  SubtitleAiConfig _config() => SubtitleAiConfig(
    origin: origin.text,
    token: token.text.trim(),
    model: modelName.text,
    target: target.text.trim(),
    prompt: prompt.text.trim().isEmpty
        ? defaultSubtitlePrompt
        : prompt.text.trim(),
  );
  Future<void> _save() async {
    setState(() {
      saving = true;
      result = '';
    });
    try {
      final config = _config();
      AppLog.instance.rememberSecret(config.token);
      await widget.model.secrets.write(
        key: 'aiSubtitleToken',
        value: config.token,
      );
      widget.model.store.markLocalModified('secret:aiSubtitleToken');
      widget.model.store.setLocal(
        'metadataCredentialsRevision',
        DateTime.now().microsecondsSinceEpoch,
      );
      await widget.model.setSettings({
        'aiSubtitleOrigin': config.origin.toString(),
        'aiSubtitleModel': config.model.trim(),
        'aiSubtitleTarget': config.target,
        'aiSubtitlePrompt': prompt.text.trim(),
      });
      if (mounted) showGlassSuccess(context, '翻译设置已保存');
    } catch (e) {
      if (mounted) {
        setState(() => result = safeFailure(e, action: '保存失败').message);
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _loadModels() async {
    _cancel?.cancel();
    final cancel = CancelToken();
    _cancel = cancel;
    setState(() {
      loadingModels = true;
      result = '';
    });
    try {
      final config = SubtitleAiConfig(
        origin: origin.text,
        token: token.text.trim(),
        model: '',
      );
      AppLog.instance.rememberSecret(config.token);
      final available = await (widget.transport ?? IoSubtitleAiTransport())
          .models(config, cancel);
      if (!mounted || cancel.cancelled) return;
      setState(() {
        models = available.toSet().toList()..sort();
        result = models.isEmpty
            ? '连接成功，服务没有列出模型，可手动填写模型名称'
            : '已加载 ${models.length} 个模型，点击“选择模型”后保存';
      });
    } catch (e) {
      if (mounted && !cancel.cancelled) {
        setState(() => result = safeFailure(e, action: '加载模型失败').message);
      }
    } finally {
      if (mounted && identical(_cancel, cancel)) {
        setState(() => loadingModels = false);
      }
    }
  }

  Future<void> _chooseModel() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _ModelPicker(models: models, selected: modelName.text),
    );
    if (value != null && mounted) setState(() => modelName.text = value);
  }

  @override
  void dispose() {
    _cancel?.cancel();
    for (final c in [origin, token, modelName, target, prompt]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: LinearProgressIndicator(),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: origin,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'API 地址',
            hintText: 'https://api.example.com/v1',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: token,
          obscureText: !reveal,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'API Key',
            suffixIcon: IconButton(
              tooltip: reveal ? '隐藏' : '显示',
              onPressed: () => setState(() => reveal = !reveal),
              icon: Icon(
                reveal
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: modelName,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '模型名称',
            helperText: '从服务加载后选择，也可直接输入模型名称',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            OutlinedButton.icon(
              onPressed: saving || loadingModels ? null : _loadModels,
              icon: loadingModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download_outlined, size: 18),
              label: Text(loadingModels ? '加载中…' : '加载模型'),
            ),
            OutlinedButton.icon(
              onPressed: saving || loadingModels || models.isEmpty
                  ? null
                  : _chooseModel,
              icon: const Icon(Icons.unfold_more_rounded, size: 18),
              label: const Text('选择模型'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: target,
          decoration: const InputDecoration(labelText: '目标语言'),
        ),
        const SizedBox(height: 10),
        ExpansionTile(
          key: const PageStorageKey<String>('ai-subtitle-prompt-expanded'),
          tilePadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: const Text('字幕翻译要求'),
          children: [
            TextField(
              // The editable's scroll offset must not reuse the tile's bool state.
              key: const PageStorageKey<String>('ai-subtitle-prompt-input'),
              controller: prompt,
              minLines: 2,
              maxLines: 5,
              maxLength: 10000,
              decoration: const InputDecoration(hintText: '留空使用自然、简洁的字幕翻译'),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: saving ? null : _save,
            child: Text(saving ? '保存中' : '保存'),
          ),
        ),
        if (result.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(
              result,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _ModelPicker extends StatefulWidget {
  final List<String> models;
  final String selected;
  const _ModelPicker({required this.models, required this.selected});
  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final filtered = widget.models
        .where(
          (name) => name.toLowerCase().contains(query.trim().toLowerCase()),
        )
        .toList();
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * .72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择翻译模型',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '搜索模型',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (value) => setState(() => query = value),
              ),
            ),
            Flexible(
              child: filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('没有匹配的模型'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      itemCount: filtered.length,
                      itemBuilder: (_, index) {
                        final name = filtered[index];
                        return ListTile(
                          selected: name == widget.selected,
                          title: Text(name),
                          trailing: name == widget.selected
                              ? const Icon(Icons.check_rounded)
                              : null,
                          onTap: () => Navigator.pop(context, name),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
