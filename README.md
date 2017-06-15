Guardian
========

> An authentication library for use with Elixir applications.

[![Build Status](https://travis-ci.org/ueberauth/guardian.svg?branch=master)](https://travis-ci.org/ueberauth/guardian)

> Looking for [Guardian pre 1.0](https://github.com/ueberauth/guardian/tree/v0.14.x)?

Guardian is a token based authentication library for use with Elixir applications.

Guardian remains a functional system. It integrates with Plug, but can be used outside of it. If you're implementing a TCP/UDP protocol directly, or want to utilize your authentication via channels in Phoenix, Guardian is your friend.

The core currency of authentication in Guardian is the _token_.
By default [JSON Web Tokens](https://jwt.io) are supported out of the box but any token that:

* Has the concept of a key-value payload
* Is tamper proof
* Can serialize to a String
* Has a supporting module that implements the `Guardian.Token` behaviour

Can be used with Guardian.

You can use Guardian tokens to authenticate:

* Web endpoints (Plug/Phoenix/X)
* Channels/Sockets (Phoenix - optional)
* Any other system you can imagine. If you can attach an authentication token you can authenticate it.

Tokens should be able to contain any assertions (claims) that a developer wants to make and may contain both standard and application specific information encoded within them.

Guardian also allows you to configure multiple token types/configurations in a single application.

## Useful articles

## Installation

Add Guardian to your application

mix.exs

```elixir
defp deps do
  [
    # ...
    {:guardian, "~> 1.0"}
    # ...
  ]
end
```

Create a module that uses `Guardian`

```elixir
defmodule MyApp.AuthTokens do
  use Guardian, otp_app: :my_app

  def subject_for_token(resource, _claims) do
    to_string(resource.id)
  end

  def resource_from_claims(claims) do
    find_me_a_resource(claims["sub"])
  end
end
```

Add your configuration

```elixir
config :my_app, MyApp.AuthTokens,
       issuer: "my_app"
       secret_key: "Secret key. You can use `mix phx.gen.secret` to get one"
```

With this level of configuration you can have a working installation.

## Basics

```elixir
# encode a token for a resource
{:ok, token, claims} = MyApp.AuthTokens.encode_and_sign(resource)

# decode and verify a token
{:ok, claims} = MyApp.AuthTokens.decode_and_verify(token)

# revoke a token (use GuardianDb or something similar if you need revoke to actually track a token)
{:ok, claims} = MyApp.AuthTokens.revoke(token)

# Refresh a token before it expires
{:ok, _old_stuff, {new_token, new_claims}} = MyApp.AuthTokens.refresh(token)

# Exchange a token of type "X" for a new token of type "Y"
{:ok, _old_stuff, {new_token, new_claims}} = MyApp.AuthTokens.exchange(token, "X", "Y")

# Lookup a resource directly from a token
{:ok, resource, claims} = MyApp.AuthTokens.resource_from_token(token)
```

With Plug

```elixir
# If a session is loaded the token/resource/claims will be put into the session and connection
# If no session is loaded, the token/resource/claims only go onto the connection
conn = MyApp.AuthTokens.Plug.sign_in(conn, resource)

# remove from session (if fetched) and revoke the token
conn = MyApp.AuthTokens.Plug.sign_out(conn)

# Set a "refresh" token directly on a cookie.
# Can be used in conjunction with `Guardian.Plug.VerifyCookie`
conn = MyApp.AuthTokens.Plug.remember_me(conn, resource)

# Fetch the information from the current connection
conn = MyApp.AuthTokens.Plug.current_token(conn)
conn = MyApp.AuthTokens.Plug.current_claims(conn)
conn = MyApp.AuthTokens.Plug.current_resource(conn)
```

Creating with custom claims and options

```elixir
# Add custom claims to a token
{:ok, token, claims} = MyApp.AuthTokens.encode_and_sign(resource, %{some: "claim"})

# Create a specific token type (i.e. "access"/"refresh" etc)
{:ok, token, claims} = MyApp.AuthTokens.encode_and_sign(resource, %{}, token_type: "refresh")

# Customize the time to live (ttl) of the token
{:ok, token, claims} = MyApp.AuthTokens.encode_and_sign(resource, %{}, token_ttl: {1, :minute})

# Customize the secret
{:ok, token, claims} = MyApp.AuthTokens.encode_and_sign(resource, %{}, secret: "custom")
{:ok, token, claims} = MyApp.AuthTokens.encode_and_sign(resource, %{}, secret: {SomeMod, :some_func})
{:ok, token, claims} = MyApp.AuthTokens.encode_and_sign(resource, %{}, secret: {SomeMod, :some_func, ["some", "args"]})
{:ok, token, claims} = MyApp.AuthTokens.encode_and_sign(resource, %{}, secret: fn -> "secret" end)
```

Decoding tokens

```elixir
# Check some literal claims. (i.e. this is an access token)
{:ok, claims} = MyApp.AuthTokens.decode_and_verify(token, %{"typ" => "access"})

# Use a custom secret
{:ok, claims} = MyApp.AuthTokens.decode_and_verify(token, %{}, secret: "custom")
{:ok, claims} = MyApp.AuthTokens.decode_and_verify(token, %{}, secret: {SomeMod, :some_func})
{:ok, claims} = MyApp.AuthTokens.decode_and_verify(token, %{}, secret: {SomeMod, :some_func, ["some", "args"]})
{:ok, claims} = MyApp.AuthTokens.decode_and_verify(token, %{}, secret: fn -> "secret" end)
```

## Configuration

The following configuration is available to all token modules.

* `token_module` - The module that implements the functions for dealing with tokens. Default `Guardian.Token.Jwt`

Guardian can handle tokens of any type that implement the `Guardian.Token` behaviour.
Each token module will have it's own configuration requirements. Please see below for the JWT configuration.

All configuration values may be provided in two ways.

1. In your config files
2. As a Keyword list to your call to `use Guardian` in you implementation module.

Any options given to `use Guardian` have precedence over config values found in the config files.

Some configuration may be required by your `token_module`

### Configuration values

Guardian resolves different types of configuration values. These can be provided in the config or options as:

* `{:system, "FOO"}` - Read from the system environment
* `{MyModule, :function_name}` - To call a function and use the result
* `{MyModule, :func, [:some, :args]}` Calls the function on the module with args
* `fn -> :some_value end` - an anonymous function whose result will be used
* any other value

These are evaluated at runtime and any value that you fetch via

`MyApp.AuthTokens.config(key, default)` will be resolved using this scheme.

See `Guardian.Config.resolve_value/1` for more information.

### JWT (Configuration)

The default token type of `Guardian` is Jwt. I accepts many options but you really only _need_ to specify the `issuer` and `secret_key`

#### Required configuration (JWT)

* `issuer` - The issuer of the token. Your application name/id
* `secret_key` - The secret key to use for the implementation module.
                 This may be any resolvable value for `Guardian.Config`

#### Optional configuration (JWT)

* `token_verify_module` - default `Guardian.Token.Jwt.Verify`. The module that verifies the claims
* `allowed_algos` - The allowed algos to use for encoding and decoding.
                    See `JOSE` for available. Default ["HS512"]
* `ttl` - The default time to live for all tokens. See the type in Guardian.ttl
* `token_ttl` a map of `token_type` to `ttl`. Set specific ttls for specific types of tokens
* `allowed_drift` The drift that is allowed when decoding/verifying a token in milli seconds
* `verify_issuer` Default false

## Secrets (JWT)

Secrets can be simple strings or more complicated `JOSE` secret schemes.

The simplest way to use the JWT module is to provide a simple String. (`mix phx.gen.secret` works great)

You can provide a system env string value by using `secret_key: {:system, "MY_TOKEN_SECRET"}` and setting the `MY_TOKEN_SECRET` in your environment.

Alternatively you can use a module and function by adding `secret_key: {MyModule, :function_name}`.

More advanced secret information can be found below.

## Using options in calls

Almost all of the functions provided by `Guardian` utilize options as the last argument.
These options are passed from the initiating call through to the `token_module` and also your `callbacks`. See the documentation for your `token_module` (`Guardian.Token.Jwt` by default) for more information.

## Hooks

Each implementation module (modules that `use Guardian`) implement callbacks for the `Guardian` behaviour. By default these are just pass-through but you can implement your own version to tweak the behaviour of your tokens.

The callbacks are:

* `after_encode_and_sign`
* `after_sign_in`
* `before_sign_out`
* `build_claims` - Use this to tweak the claims that you include in your token
* `default_token_type` - default is `"access"`
* `on_exchange`
* `on_revoke`
* `on_refresh`
* `on_verify`
* `verify_claims` - You can add custom validations for your tokens in this callback

## Plugs

Guardian provides various plugs to help work with web requests in Elixir.
Guardians plugs are optional and will not be compiled if you're not using Plug in your application.

All plugs need to be in a `pipeline`.
A pipeline is just a way to get the implementation module and error handler
into the connection for use downstream. More information can be found in the `Pipelines` section.

### Plugs and keys (advanced usage)

All Plugs and related functions provided by `Guardian` have the concept of a `key`.
A `key` specifies a label that is used to keep tokens separate so that you can have multiple token/resource/claims active in a single request.

In your plug pipeline you may use something like:

```elixir
plug Guardian.Plug.VerifyHeader, realm: "bearer", key: :impersonate
plug Guardian.Plug.EnsureAuthenticated, key: :impersonate
```

In your action handler:

```elixir
resource = MyApp.AuthTokens.Plug.current_resource(conn, key: :impersonate)
claims = MyApp.AuthTokens.Plug.current_claims(conn, key: :impersonate)
```

### Plugs out of the box

#### `Guardian.Plug.VerifyHeader`
Look for a token in the header and verify it

#### `Guardian.Plug.VerifySession`
Look for a token in the session and verify it

#### `Guardian.Plug.VerifyCookie`
Look for a token in cookies and exchange it for an access token

#### `Guardian.Plug.EnsureAuthenticated`
Make sure that a token was found and is valid

#### `Guardian.Plug.EnsureNotAuthenticated`
Make sure no one is logged in

#### `Guardian.Plug.LoadResource`
If a token was found, load the resource for it

See the documentation for each Plug for more information.

### Pipelines

A pipeline is a way to collect together the various plugs for a particular authentication scheme.

Apart from keeping an authentication flow together, pipelines provide downstream information for error handling and which token module to use.

#### Create a pipeline

```elixir
defmodule MyApp.AuthAccessPipeline do
  use Guardian.Plug.Pipeline, otp_app: :my_app,
                              module: MyApp.AuthTokens,
                              error_handler: MyApp.AuthErrorHandler

  alias Guardian.Plug.{
    EnsureAuthenticated,
    LoadResource,
    VerifySession,
    VerifyHeader,
  }

  plug VerifySession, claims: %{"typ" => "access"}
  plug VerifyHeader, claims: %{"typ" => "access"}, realm: "Bearer"
  plug EnsureAuthenticated
  plug LoadResource, ensure: true
end
```

By using a pipeline, apart from keeping your auth logic together, you're instructing downstream plugs to use a particular token module and error handler.

If you wanted to do that manually:

```elixir
plug Guardian.Plug.Pipeline, module: MyApp.AuthTokens,
                             error_handler: MyApp.AuthErrorHandler

plug Guardian.Plug.VerifySession
```

### Plug Error handlers

The error handler is a module that implements an `auth_error` function.

```elixir
defmodule MyApp.AuthErrorHandler do
  import Plug.Conn

  def auth_error(conn, {type, reason}, _opts) do
    body = Poison.encode!(%{message: to_string(type)})
    send_resp(conn, 401, body)
  end
end
```

## Permissions

## Tracking Tokens

## Testing

## Related projects

## More advanced secrets

By specifying a binary, the default behavior is to treat the key as an [`"oct"`](https://tools.ietf.org/html/rfc7518#section-6.4) key type (short for octet sequence). This key type may be used with the `"HS256"`, `"HS384"`, and `"HS512"` signature algorithms.

Alternatively, a configuration value that resolves to:

* `Map`
* `Function`
* `%JOSE.JWK{} Struct`

may be specified for other key types. A full list of example key types is available [here](https://gist.github.com/potatosalad/925a8b74d85835e285b9).

See the [key generation docs](https://hexdocs.pm/jose/key-generation.html) from jose for how to generate your own keys.

To get off the ground quickly, set your `secret_key` in your Guardian config with the output of either:

`$ mix phoenix.gen.secret`

or

`iex(1)> JOSE.JWS.generate_key(%{"alg" => "HS512"}) |> JOSE.JWK.to_map |> elem(1) |> Map.take(["k", "kty"])`

After running `$ mix deps.get` because JOSE is one of Guardian's dependencies.

```elixir
## Map ##

config :my_app, MyApp.AuthTokens,
  allowed_algos: ["ES512"],
  secret_key: %{
    "crv" => "P-521",
    "d" => "axDuTtGavPjnhlfnYAwkHa4qyfz2fdseppXEzmKpQyY0xd3bGpYLEF4ognDpRJm5IRaM31Id2NfEtDFw4iTbDSE",
    "kty" => "EC",
    "x" => "AL0H8OvP5NuboUoj8Pb3zpBcDyEJN907wMxrCy7H2062i3IRPF5NQ546jIJU3uQX5KN2QB_Cq6R_SUqyVZSNpIfC",
    "y" => "ALdxLuo6oKLoQ-xLSkShv_TA0di97I9V92sg1MKFava5hKGST1EKiVQnZMrN3HO8LtLT78SNTgwJSQHAXIUaA-lV"
  }

## Tuple ##
# If, for example, you have your secret key stored externally (in this example, we're using Redix).

# defined elsewhere
defmodule MySecretKey do
  def fetch do
    # Bad practice for example purposes only.
    # An already established connection should be used and possibly cache the value locally.
    {:ok, conn} = Redix.start_link
    rsa_jwk = conn
      |> Redix.command!(["GET my-rsa-key"])
      |> JOSE.JWK.from_binary
    Redix.stop(conn)
    rsa_jwk
  end
end

config :my_app, MyApp.AuthTokens,
  allowed_algos: ["RS512"],
  secret_key: {MySecretKey, :fetch}

## %JOSE.JWK{} Struct ##
# Useful if you store your secret key in an encrypted JSON file with the passphrase in an environment variable.

# defined elsewhere
defmodule MySecretKey do
  def fetch do
    System.get_env("SECRET_KEY_PASSPHRASE") |> JOSE.JWK.from_file(System.get_env("SECRET_KEY_FILE"))
  end
end

config :my_app, MyApp.AuthTokens,
  allowed_algos: ["Ed25519"],
  secret_key: {MySecretKey, :fetch}
```
