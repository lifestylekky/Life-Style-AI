class CloudConfig {
  static const functionUrl = String.fromEnvironment(
    'SUPABASE_FUNCTION_URL',
    defaultValue:
        'https://xlgkxryniiokathvmtxo.supabase.co/functions/v1/flux-proxy',
  );

  static const appToken = String.fromEnvironment('APP_CLIENT_TOKEN');

  static bool get isConfigured => appToken.trim().isNotEmpty;

  static Map<String, String> headers({bool json = false}) => {
    'accept': 'application/json',
    'x-app-token': appToken,
    if (json) 'Content-Type': 'application/json',
  };

  static String endpoint(String path) =>
      '${functionUrl.replaceAll(RegExp(r'/$'), '')}$path';
}
