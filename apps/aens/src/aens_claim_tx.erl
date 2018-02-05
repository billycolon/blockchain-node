%%%=============================================================================
%%% @copyright (C) 2018, Aeternity Anstalt
%%% @doc
%%%    Module defining the Naming System claim transaction
%%% @end
%%%=============================================================================

-module(aens_claim_tx).

-include("ns_txs.hrl").
-include_lib("apps/aecore/include/common.hrl").
-include_lib("apps/aecore/include/trees.hrl").

-behavior(aetx).

%% Behavior API
-export([new/1,
         fee/1,
         nonce/1,
         origin/1,
         check/3,
         process/3,
         accounts/1,
         signers/1,
         serialize/1,
         deserialize/1,
         type/0,
         for_client/1
        ]).

%% Getters
-export([account/1,
         name/1]).

%%%===================================================================
%%% Types
%%%===================================================================

-define(NAME_CLAIM_TX_TYPE, <<"name_claim">>).
-define(NAME_CLAIM_TX_VSN, 1).

-opaque claim_tx() :: #ns_claim_tx{}.

-export_type([claim_tx/0]).

%%%===================================================================
%%% Behaviour API
%%%===================================================================

-spec new(map()) -> {ok, claim_tx()}.
new(#{account   := AccountPubKey,
      nonce     := Nonce,
      name      := Name,
      name_salt := NameSalt,
      fee       := Fee}) ->
    {ok, #ns_claim_tx{account   = AccountPubKey,
                      nonce     = Nonce,
                      name      = Name,
                      name_salt = NameSalt,
                      fee       = Fee}}.

-spec fee(claim_tx()) -> integer().
fee(#ns_claim_tx{fee = Fee}) ->
    Fee.

-spec nonce(claim_tx()) -> non_neg_integer().
nonce(#ns_claim_tx{nonce = Nonce}) ->
    Nonce.

-spec origin(claim_tx()) -> pubkey().
origin(#ns_claim_tx{account = AccountPubKey}) ->
    AccountPubKey.

-spec check(claim_tx(), trees(), height()) -> {ok, trees()} | {error, term()}.
check(#ns_claim_tx{account = AccountPubKey, nonce = Nonce,
                   fee = Fee, name = Name, name_salt = NameSalt}, Trees, Height) ->
    %% TODO: Maybe include burned fee in tx fee. To do so, mechanism determining
    %% which part of fee goes to miner and what gets burned is needed.
    %% One option is to change tx:fee/1 callback to tx:fee_for_miner/1.
    BurnedFee = aec_governance:name_claim_burned_fee(),

    Checks =
        [fun() -> aetx_utils:check_account(AccountPubKey, Trees, Height, Nonce, Fee + BurnedFee) end,
         fun() -> check_commitment(Name, NameSalt, AccountPubKey, Trees, Height) end,
         fun() -> check_name(Name, Trees) end],

    case aeu_validation:run(Checks) of
        ok              -> {ok, Trees};
        {error, Reason} -> {error, Reason}
    end.

-spec process(claim_tx(), trees(), height()) -> {ok, trees()}.
process(#ns_claim_tx{account = AccountPubKey, nonce = Nonce, fee = Fee,
                     name = PlainName, name_salt = NameSalt} = ClaimTx, Trees0, Height) ->
    AccountsTree0 = aec_trees:accounts(Trees0),
    NSTree0 = aec_trees:ns(Trees0),

    TotalFee = Fee + aec_governance:name_claim_burned_fee(),
    Account0 = aec_accounts_trees:get(AccountPubKey, AccountsTree0),
    {ok, Account1} = aec_accounts:spend(Account0, TotalFee, Nonce, Height),
    AccountsTree1 = aec_accounts_trees:enter(Account1, AccountsTree0),

    CommitmentHash = aens_hash:commitment_hash(PlainName, NameSalt),
    NSTree1 = aens_state_tree:delete_commitment(CommitmentHash, NSTree0),

    TTL = aec_governance:name_claim_max_expiration(),
    Name = aens_names:new(ClaimTx, TTL, Height),
    NSTree2 = aens_state_tree:enter_name(Name, NSTree1),

    Trees1 = aec_trees:set_accounts(Trees0, AccountsTree1),
    Trees2 = aec_trees:set_ns(Trees1, NSTree2),

    {ok, Trees2}.

-spec accounts(claim_tx()) -> [pubkey()].
accounts(#ns_claim_tx{account = AccountPubKey}) ->
    [AccountPubKey].

-spec signers(claim_tx()) -> [pubkey()].
signers(#ns_claim_tx{account = AccountPubKey}) ->
    [AccountPubKey].

-spec serialize(claim_tx()) -> list(map()).
serialize(#ns_claim_tx{account   = AccountPubKey,
                       nonce     = None,
                       name      = Name,
                       name_salt = NameSalt,
                       fee       = Fee}) ->
    [#{<<"type">>      => type()},
     #{<<"vsn">>       => version()},
     #{<<"account">>   => AccountPubKey},
     #{<<"nonce">>     => None},
     #{<<"name">>      => Name},
     #{<<"name_salt">> => NameSalt},
     #{<<"fee">>       => Fee}].

-spec deserialize(list(map())) -> claim_tx().
deserialize([#{<<"type">>      := ?NAME_CLAIM_TX_TYPE},
             #{<<"vsn">>       := ?NAME_CLAIM_TX_VSN},
             #{<<"account">>   := AccountPubKey},
             #{<<"nonce">>     := Nonce},
             #{<<"name">>      := Name},
             #{<<"name_salt">> := NameSalt},
             #{<<"fee">>       := Fee}]) ->
    #ns_claim_tx{account   = AccountPubKey,
                 nonce     = Nonce,
                 name      = Name,
                 name_salt = NameSalt,
                 fee       = Fee}.

-spec type() -> binary().
type() ->
    ?NAME_CLAIM_TX_TYPE.

-spec for_client(claim_tx()) -> map().
for_client(#ns_claim_tx{account   = AccountPubKey,
                        nonce     = Nonce,
                        name      = Name,
                        name_salt = NameSalt,
                        fee       = Fee}) ->
    #{<<"type">>      => <<"NameClaimTxObject">>, % swagger schema name
      <<"vsn">>       => version(),
      <<"account">>   => aec_base58c:encode(account_pubkey, AccountPubKey),
      <<"nonce">>     => Nonce,
      <<"name">>      => Name,
      <<"name_salt">> => NameSalt,
      <<"fee">>       => Fee}.

%%%===================================================================
%%% Getters
%%%===================================================================

-spec account(claim_tx()) -> pubkey().
account(#ns_claim_tx{account = AccountPubKey}) ->
    AccountPubKey.

-spec name(claim_tx()) -> binary().
name(#ns_claim_tx{name = Name}) ->
    Name.

%%%===================================================================
%%% Internal functions
%%%===================================================================

check_commitment(Name, NameSalt, AccountPubKey, Trees, Height) ->
    NSTree = aec_trees:ns(Trees),
    CH = aens_hash:commitment_hash(Name, NameSalt),
    case aens_state_tree:lookup_commitment(CH, NSTree) of
        {value, C} ->
            case aens_commitments:owner(C) =:= AccountPubKey of
                true  ->
                    CreatedAt = aens_commitments:created(C),
                    Delta = aec_governance:name_claim_preclaim_delta(),
                    if CreatedAt + Delta =< Height -> ok;
                       true -> {error, commitment_delta_too_small}
                    end;
                false -> {error, commitment_not_owned}
            end;
        none ->
            {error, name_not_preclaimed}
    end.

check_name(Name, Trees) ->
    NSTree = aec_trees:ns(Trees),
    NHash = aens_hash:name_hash(Name),
    case aens_state_tree:lookup_name(NHash, NSTree) of
        {value, _} ->
            {error, name_already_taken};
        none ->
            ok
    end.


version() ->
    ?NAME_CLAIM_TX_VSN.
