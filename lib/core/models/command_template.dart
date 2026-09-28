/// A saved, named set of extra yt-dlp arguments.
///
/// Modelled on Seal's custom command templates: the same few argument sets get
/// pasted in repeatedly (split fragments, sponsorblock, embed metadata), and
/// keeping them named is cheaper than retyping. Templates only ever hold
/// *arguments* — never a full command line, because the executable, output path
/// and URL are the app's business.
class CommandTemplate {
  const CommandTemplate({required this.name, required this.args});

  final String name;

  /// The raw argument text, exactly as typed. Tokenised on use, so a template
  /// is stored exactly as written and re-parsed when applied.
  final String args;

  /// Whether the template has a usable name to show in a picker.
  bool get isNamed => name.trim().isNotEmpty;

  Map<String, dynamic> toMap() => {'name': name, 'args': args};

  factory CommandTemplate.fromMap(Map<String, dynamic> m) => CommandTemplate(
    name: m['name'] as String? ?? '',
    args: m['args'] as String? ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is CommandTemplate && other.name == name && other.args == args;

  @override
  int get hashCode => Object.hash(name, args);
}
