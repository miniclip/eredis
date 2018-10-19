-module(eredis_security).

-include_lib("public_key/include/OTP-PUB-KEY.hrl").

-export(
   [secure_ssl_opts/2,
    partial_chain/1
   ]).

%%==============================================================================
%% Exported functions
%%==============================================================================

-spec secure_ssl_opts(string(), [ssl:option()]) -> [ssl:option(), ...].
secure_ssl_opts(Host, Opts) ->
    lists:foldr(
      fun ({Key, Value}, Acc) ->
              lists:keystore(Key, 1, Acc, {Key,Value})
      end,
      Opts,
      secure_ssl_opts(Host)).

-spec partial_chain([public_key:der_encoded()]) -> {trusted_ca, binary()} | unknown_ca.
partial_chain(Certs) ->
    % Taken from frisky, which took it from hackney,
    % licensed under Apache 2 license,
    % which in turn took it from rebar3, licensed under BSD.
    Certs1 = lists:reverse([{Cert, public_key:pkix_decode_cert(Cert, otp)} ||
                            Cert <- Certs]),
    CACerts = certifi:cacerts(),
    CACerts1 = [public_key:pkix_decode_cert(Cert, otp) || Cert <- CACerts],

    case lists_anymap(
           fun ({_, Cert}) ->
                   check_cert(CACerts1, Cert)
           end,
           Certs1)
    of
        {true, Trusted} ->
            {trusted_ca, element(1, Trusted)};
        false ->
            unknown_ca
    end.

%%==============================================================================
%% Internal functions
%%==============================================================================

secure_ssl_opts(Host) ->
    % Taken from frisky, which took it from hackney,
    % licensed under Apache 2 license.
    CACerts = certifi:cacerts(),
    VerifyFun =
    {fun ssl_verify_hostname:verify_fun/3,
     [{check_hostname, Host}]
    },
    [{verify, verify_peer},
     {depth, 99},
     {cacerts, CACerts},
     {partial_chain, fun ?MODULE:partial_chain/1},
     {verify_fun, VerifyFun}].

check_cert(CACerts, Cert) ->
    % Taken from frisky, which took it from hackney,
    % licensed under Apache 2 license.
    CertPKI = extract_public_key_info(Cert),
    lists:any(
      fun(CACert) ->
              extract_public_key_info(CACert) =:= CertPKI
      end, CACerts).

extract_public_key_info(Cert) ->
    ((Cert#'OTPCertificate'.tbsCertificate)#'OTPTBSCertificate'.subjectPublicKeyInfo).

lists_anymap(Fun, [H|T]) ->
    case Fun(H) of
        true -> {true, H};
        false -> lists_anymap(Fun, T)
    end;
lists_anymap(_Fun, []) ->
    false.
