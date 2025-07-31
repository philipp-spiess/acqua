import Config

# Configuration for esshd
config :esshd,
  enabled: true,
  port: 1234,
  priv_dir: "ssh_keys",
  handler: "SshAquarium.ShellHandler",
  public_key_authenticator: "Sshd.PublicKeyAuthenticator.AcceptAll",
  password_authenticator: "Sshd.PasswordAuthenticator.DenyAll",
  max_sessions: 100,
  parallel_login: true,
  idle_time: 300_000,
  negotiation_timeout: 5_000