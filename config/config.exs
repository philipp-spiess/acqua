import Config

# Configuration for esshd
config :esshd,
  enabled: true,
  port: 1234,
  priv_dir: "ssh_keys",
  handler: "SshAquarium.ShellHandler",
  public_key_authenticator: "Sshd.PublicKeyAuthenticator.AcceptAll",
  password_authenticator: "Sshd.PasswordAuthenticator.AcceptAll",
  max_sessions: 100,
  parallel_login: true,
  idle_time: 300_000,
  negotiation_timeout: 5_000

# Configure logger - you can adjust the level to :warn to suppress info messages
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Set minimum log level (uncomment the line below to suppress info logs)
# config :logger, level: :warn