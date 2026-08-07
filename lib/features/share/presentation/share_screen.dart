import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxer_app/core/router/fluxer_router.dart';
import 'package:fluxer_app/core/router/route_names.dart';
import 'package:fluxer_app/core/share/share_handler.dart';
import 'package:fluxer_app/core/theme/fluxer_theme_extension.dart';
import 'package:fluxer_app/features/channels/utils/navigate_to_channel_content.dart';
import 'package:fluxer_app/features/chat/providers/core/chat_providers.dart';
import 'package:fluxer_app/features/dm/presentation/widgets/create_dm_body.dart';
import 'package:fluxer_app/features/dm/providers/create_dm_view_model.dart';
import 'package:fluxer_app/features/ui/ui.dart';
import 'package:fluxer_app/l10n/generated/fluxer_localizations.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

class ShareScreen extends ConsumerStatefulWidget {
  const ShareScreen({super.key});

  @override
  ConsumerState<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends ConsumerState<ShareScreen> {
  CreateDmController? _controller;
  late final ScrollController _scrollController;
  bool _isSending = false;
  bool _didInit = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _controller
      ?..removeListener(_handleControllerChanged)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _ensureController() {
    if (_controller != null || !mounted) {
      return;
    }
    _controller = CreateDmController(
      container: ref.container,
      options: const CreateDmOptions(maxSelections: 1),
      onCreated: _handleCreated,
    );
    _controller!.addListener(_handleControllerChanged);
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _handleCreated(String channelId) async {
    // For the share flow, we don't navigate on creation — we send the message
    // to the created/found channel, then navigate.
    await _sendSharedContent(channelId);
  }

  Future<void> _sendSharedContent(String channelId) async {
    final payload = ref.read(shareHandlerProvider);
    if (payload == null || payload.isEmpty) {
      // Nothing to share — just navigate to the channel.
      if (!mounted) {
        return;
      }
      await navigateToDmChannelContent(
        context: context,
        ref: ref,
        channelId: channelId,
      );
      return;
    }

    setState(() => _isSending = true);
    try {
      final messageRepo = ref.read(messageRepositoryProvider);
      await messageRepo.sendMessage(
        channelId: channelId,
        content: payload.text ?? '',
      );
      ref.read(shareHandlerProvider.notifier).clear();
      if (!mounted) {
        return;
      }
      await navigateToDmChannelContent(
        context: context,
        ref: ref,
        channelId: channelId,
      );
    } on Object catch (_) {
      if (!mounted) {
        return;
      }
      final l10n = FluxerLocalizations.of(context);
      ref.read(toastProvider.notifier).show(
            FluxerToast(message: l10n.shareSendFailed),
          );
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  void _handleCancel() {
    ref.read(shareHandlerProvider.notifier).clear();
    ref.read(fluxerRouterProvider).go(RoutePaths.me);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = FluxerLocalizations.of(context);
    final payload = ref.watch(shareHandlerProvider);

    // Ensure controller is created once we can access ref.
    if (!_didInit) {
      _didInit = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureController();
        if (mounted) {
          setState(() {});
        }
      });
    }

    final controller = _controller;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _handleCancel();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: PhosphorIcon(PhosphorIconsBold.x, size: 22),
            onPressed: _handleCancel,
          ),
          title: Text(l10n.shareTitle),
        ),
        body: controller == null
            ? const Center(child: FluxerLoadingSpinner())
            : SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Shared content preview
                    if (payload != null && !payload.isEmpty)
                      _ShareContentPreview(payload: payload),
                    // Friend selector
                    Expanded(
                      child: CreateDmBody(
                        controller: controller,
                        scrollController: _scrollController,
                        showInlineSearch: true,
                      ),
                    ),
                    // Action buttons
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        context.layout.s4,
                        context.layout.s3,
                        context.layout.s4,
                        context.layout.s4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FluxerButton.primary(
                            label: l10n.shareSend,
                            isLoading:
                                controller.isCreating || _isSending,
                            onPressed: (controller.isCreating ||
                                    _isSending ||
                                    controller.selectedUserIds.isEmpty ||
                                    controller.restriction != null)
                                ? null
                                : () => unawaited(
                                      controller.handleCreateWithDuplicateCheck(
                                        context,
                                        ref,
                                      ),
                                    ),
                          ),
                          const SizedBox(height: 8),
                          FluxerButton.secondary(
                            label: l10n.cancel,
                            onPressed: _handleCancel,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _ShareContentPreview extends StatelessWidget {
  const _ShareContentPreview({required this.payload});

  final SharePayload payload;

  @override
  Widget build(BuildContext context) {
    final text = payload.text;
    final hasText = text != null && text.isNotEmpty;
    if (!hasText) {
      return const SizedBox.shrink();
    }

    // Truncate very long shared text for the preview.
    final displayText = text.length > 200
        ? '${text.substring(0, 200)}…'
        : text;

    return Container(
      margin: EdgeInsets.all(context.layout.s4),
      padding: EdgeInsets.all(context.layout.s3),
      decoration: BoxDecoration(
        color: context.colors.backgroundSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.colors.borderColor,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PhosphorIcon(
            PhosphorIconsRegular.link,
            size: 18,
            color: context.colors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              displayText,
              style: context.textStyles.bodyMedium.copyWith(
                color: context.colors.textSecondary,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
