enum ChatRole { system, user, assistant }

class ChatMessage {
  ChatMessage({required this.role, required this.content});

  final ChatRole role;
  final String content;

  Map<String, String> toJson() => {
        'role': switch (role) {
          ChatRole.system => 'system',
          ChatRole.user => 'user',
          ChatRole.assistant => 'assistant',
        },
        'content': content,
      };

  static ChatMessage fromJson(Map<String, dynamic> json) {
    final roleStr = (json['role'] ?? '').toString();
    final role = switch (roleStr) {
      'system' => ChatRole.system,
      'assistant' => ChatRole.assistant,
      _ => ChatRole.user,
    };
    return ChatMessage(role: role, content: (json['content'] ?? '').toString());
  }
}
