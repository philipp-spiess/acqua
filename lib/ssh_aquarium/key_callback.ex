defmodule SshAquarium.KeyCallback do
  @moduledoc """
  SSH key callback that accepts any public key for authentication.
  """
  
  @behaviour :ssh_server_key_api
  
  # Accept any public key from any user
  def is_auth_key(_key, _user, _opts) do
    true
  end
  
  # Let the default implementation handle host keys from system_dir
  def host_key(algorithm, opts) do
    :ssh_file.host_key(algorithm, opts)
  end
  
  # Add a key (no-op for this implementation)
  def add_host_key(_hostname, _key, _opts) do
    :ok
  end
  
  # Check if host key is trusted (always yes)
  def is_host_key(_key, _hostname, _algorithm, _opts) do
    true
  end
end