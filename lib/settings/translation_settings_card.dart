/// 设置页 - AI 字幕翻译设置组件。
library;

import 'package:flutter/material.dart';

import '../subtitle/translation/translation_engine.dart';
import '../subtitle/translation/translation_service.dart';
import 'app_settings.dart';

class TranslationSettingsCard extends StatefulWidget {
  const TranslationSettingsCard({super.key});

  @override
  State<TranslationSettingsCard> createState() => _TranslationSettingsCardState();
}

class _TranslationSettingsCardState extends State<TranslationSettingsCard> {
  late TextEditingController _baiduAppIdCtrl;
  late TextEditingController _baiduSecretKeyCtrl;

  late TextEditingController _azureKeyCtrl;
  late TextEditingController _azureRegionCtrl;

  late TextEditingController _localEndpointCtrl;

  bool _obscureBaiduSecret = true;
  bool _obscureAzureKey = true;

  bool _testingConnection = false;

  @override
  void initState() {
    super.initState();
    _baiduAppIdCtrl = TextEditingController(text: aiBaiduAppId.value);
    _baiduSecretKeyCtrl = TextEditingController(text: aiBaiduSecretKey.value);

    _azureKeyCtrl = TextEditingController(text: aiAzureKey.value);
    _azureRegionCtrl = TextEditingController(
      text: aiAzureRegion.value.isNotEmpty ? aiAzureRegion.value : 'eastasia',
    );

    _localEndpointCtrl = TextEditingController(text: aiLocalEndpoint.value);
  }

  @override
  void dispose() {
    _baiduAppIdCtrl.dispose();
    _baiduSecretKeyCtrl.dispose();
    _azureKeyCtrl.dispose();
    _azureRegionCtrl.dispose();
    _localEndpointCtrl.dispose();
    super.dispose();
  }

  void _saveBaidu() {
    setAiBaiduCredentials(
      appId: _baiduAppIdCtrl.text.trim(),
      secretKey: _baiduSecretKeyCtrl.text.trim(),
    );
  }

  void _saveAzure() {
    setAiAzureCredentials(
      key: _azureKeyCtrl.text.trim(),
      region: _azureRegionCtrl.text.trim().isNotEmpty
          ? _azureRegionCtrl.text.trim()
          : 'eastasia',
      endpoint: '',
    );
  }

  void _saveLocal() {
    setAiLocalEndpoint(_localEndpointCtrl.text.trim());
  }

  Future<void> _testConnection() async {
    // 先保存当前输入
    _saveBaidu();
    _saveAzure();
    _saveLocal();

    setState(() => _testingConnection = true);
    final engine = TranslationService.instance.getActiveEngine();

    try {
      final result = await engine.testConnection();
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.green),
              SizedBox(width: 8),
              Text('测试连接成功', style: TextStyle(fontSize: 17)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('测试引擎：${engine.displayName}', style: const TextStyle(fontSize: 13.5)),
              const SizedBox(height: 8),
              const Text('测试原文："Hello"', style: TextStyle(fontSize: 13.5)),
              const SizedBox(height: 4),
              Text('翻译结果："$result"', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.error_outline_rounded, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('测试连接失败', style: TextStyle(fontSize: 17)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('测试引擎：${engine.displayName}', style: const TextStyle(fontSize: 13.5)),
                const SizedBox(height: 10),
                const Text('错误信息：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    '$e',
                    style: const TextStyle(fontSize: 12.5, color: Colors.redAccent),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('排查建议：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  engine.id == 'baidu'
                      ? '1. 请确认填写的是【开发者信息】页面的 APP ID 和密钥，不要使用“API Key 管理”里的大模型 Key。\n2. 请确认在百度翻译开放平台已成功开通【通用文本翻译】服务。\n3. 请检查本地网络连接。'
                      : '1. 请确认【位置/区域】与 Azure 控制台一致（如 eastasia）。\n2. 请确认密钥正确复制完整。\n3. 请检查本地网络连接。',
                  style: const TextStyle(fontSize: 12, height: 1.45),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge([
        aiTranslationEnabled,
        aiTranslationTargetLang,
        aiTranslationMode,
        aiTranslationProvider,
      ]),
      builder: (context, _) {
        final isEnabled = aiTranslationEnabled.value;
        final targetLang = aiTranslationTargetLang.value;
        final mode = aiTranslationMode.value;
        final provider = aiTranslationProvider.value;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 翻译开关
            SwitchListTile(
              secondary: Icon(
                Icons.translate_rounded,
                color: scheme.primary,
              ),
              title: const Text('启用 AI 字幕翻译'),
              subtitle: const Text('支持翻译视频内置字幕或 AI 识别字幕为目标语言。'),
              value: isEnabled,
              onChanged: (val) => setAiTranslationEnabled(val),
            ),
            if (isEnabled) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. 目标语言优先配置
                    Row(
                      children: [
                        Text(
                          '翻译目标语言',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '(首要设置)',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.6),
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: targetLang,
                          borderRadius: BorderRadius.circular(8),
                          items: TranslationLanguage.supportedLanguages.map((lang) {
                            return DropdownMenuItem<String>(
                              value: lang.code,
                              child: Text(
                                '${lang.name} [${lang.code}]',
                                style: const TextStyle(fontSize: 13.5),
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) setAiTranslationTargetLang(val);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 2. 翻译方式单选 (本地模型 vs 在线 API)
                    Text(
                      '翻译引擎方式',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment<String>(
                            value: 'online',
                            icon: Icon(Icons.cloud_outlined, size: 18),
                            label: Text('在线 API (推荐)'),
                          ),
                          ButtonSegment<String>(
                            value: 'local',
                            icon: Icon(Icons.memory_rounded, size: 18),
                            label: Text('本地模型 (离线)'),
                          ),
                        ],
                        selected: {mode},
                        onSelectionChanged: (set) {
                          setAiTranslationMode(set.first);
                        },
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 3. 分支：本地模型
                    if (mode == 'local') ...[
                      _buildLocalModeSection(scheme),
                    ] else ...[
                      // 4. 分支：在线 API (百度 / 腾讯 / 微软)
                      _buildOnlineModeSection(scheme, provider),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildLocalModeSection(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                '离线本地翻译模型规划中',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '轻量离线神经机器翻译模型（NLLB / ONNX）正在规划适配中。目前推荐在上方切换为「在线 API」，百度与微软 Azure 均提供充足的每月免费额度。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          // 本地服务接口（预留）
          TextField(
            controller: _localEndpointCtrl,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              labelText: '自定义本地兼容服务地址 (可选预留)',
              hintText: '如 http://127.0.0.1:11434',
              border: const OutlineInputBorder(),
              suffixIcon: _localEndpointCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _localEndpointCtrl.clear();
                        _saveLocal();
                      },
                    )
                  : null,
            ),
            onChanged: (_) => _saveLocal(),
          ),
        ],
      ),
    );
  }

  Widget _buildOnlineModeSection(ColorScheme scheme, String provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 供应商单选
        Text(
          '在线服务提供商',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('百度翻译'),
              selected: provider == 'baidu',
              onSelected: (sel) {
                if (sel) setAiTranslationProvider('baidu');
              },
            ),
            ChoiceChip(
              label: const Text('微软 Azure 翻译'),
              selected: provider == 'azure',
              onSelected: (sel) {
                if (sel) setAiTranslationProvider('azure');
              },
            ),
          ],
        ),
        const SizedBox(height: 14),

        // 表单区
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (provider == 'baidu') ...[
                _buildBaiduForm(scheme),
              ] else ...[
                _buildAzureForm(scheme),
              ],
              const SizedBox(height: 14),
              // 测试连接按钮
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _testingConnection ? null : _testConnection,
                    icon: _testingConnection
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check_rounded, size: 18),
                    label: Text(_testingConnection ? '正在测试...' : '测试连接'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '输入凭据后点测试，立即验证 API 有效性。',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBaiduForm(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.vpn_key_outlined, size: 16),
            const SizedBox(width: 6),
            Text(
              '百度通用翻译 API 配置',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _baiduAppIdCtrl,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'APP ID',
            hintText: '百度翻译开放平台控制台的 APP ID',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => _saveBaidu(),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _baiduSecretKeyCtrl,
          obscureText: _obscureBaiduSecret,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            labelText: '密钥',
            hintText: '输入百度翻译密钥',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureBaiduSecret ? Icons.visibility_off : Icons.visibility,
                size: 18,
              ),
              onPressed: () {
                setState(() => _obscureBaiduSecret = !_obscureBaiduSecret);
              },
            ),
          ),
          onChanged: (_) => _saveBaidu(),
        ),
        const SizedBox(height: 6),
        Text(
          '提示：请填写百度翻译开放平台「开发者信息」页面的 APP ID 与 密钥；切勿填写大模型或“API Key 管理”中的 Key。',
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildAzureForm(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.vpn_key_outlined, size: 16),
            const SizedBox(width: 6),
            Text(
              '微软 Azure 翻译服务配置',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _azureKeyCtrl,
          obscureText: _obscureAzureKey,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            labelText: '密钥',
            hintText: '输入 Azure 翻译密钥',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureAzureKey ? Icons.visibility_off : Icons.visibility,
                size: 18,
              ),
              onPressed: () {
                setState(() => _obscureAzureKey = !_obscureAzureKey);
              },
            ),
          ),
          onChanged: (_) => _saveAzure(),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _azureRegionCtrl,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            labelText: '位置/区域',
            hintText: '如：eastasia',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => _saveAzure(),
        ),
        const SizedBox(height: 6),
        Text(
          '提示：请确认「位置/区域」与 Azure 控制台完全一致（默认：eastasia）。',
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
