defmodule Sshd.PasswordAuthenticator do
  @moduledoc """
  This module helps to implement password-based authentication.
  """

  @type username :: charlist()
  @type password :: charlist()

  defmacro __using__(_) do
    quote do
      @behaviour Sshd.PasswordAuthenticator

      @type username :: charlist()
      @type password :: charlist()

      def authenticate(username, password), do: false

      defoverridable [
        {:authenticate, 2}
      ]
    end
  end

  @doc """
  Returns a boolean which determines if the `username` user with password
  `password` is authorized to connect to the SSH server.
  """
  @callback authenticate(username, password) :: boolean
end

defmodule Sshd.PasswordAuthenticator.Default do
  @moduledoc """
  Default implementation of password-based authentication.
  """
  use Sshd.PasswordAuthenticator
end

defmodule Sshd.PasswordAuthenticator.Test do
  @moduledoc """
  Default implementation of password-based authentication used during unit-testing.
  """
  use Sshd.PasswordAuthenticator

  def authenticate(username, password) do
    username == ~c"tests" and password == ~c"testpass"
  end
end

defmodule Sshd.PasswordAuthenticator.AcceptAll do
  @moduledoc """
  Password authenticator that accepts all users without requiring a password.
  """
  use Sshd.PasswordAuthenticator

  def authenticate(_username, _password), do: true
end
