%%%-------------------------------------------------------------------
%%% @copyright (C) 2017, Aeternity Anstalt
%%% @doc
%%% ADT for keeping the state of oracles
%%% @end
%%%-------------------------------------------------------------------

-module(aeo_state_tree).

%% API
-export([ commit_to_db/1
        , get_query/3
        , get_oracle/2
        , get_oracle_query_ids/2
        , empty/0
        , empty_with_backend/0
        , enter_query/2
        , insert_query/2
        , insert_oracle/2
        , lookup_query/3
        , lookup_oracle/2
        , prune/2
        , root_hash/1
        ]).

-ifdef(TEST).
-export([ query_list/1
        , oracle_list/1
        ]).
-endif.

%% The oracle state tree keep track of oracles and its associated queries
%% (query objects). The naive approach, storing the queries directly
%% in the oracle field in the state tree, does not work well. Since the state
%% tree has to be a Merkle tree all nodes are serialized. This would mean
%% deserialize/serialize of all queries when adding or updating a single
%% query. Instead we store the queries prefixed with the oracle id in
%% the same tree as the oracles. This is to enable iteration over a single
%% oracle's queries.

%%%===================================================================
%%% Types
%%%===================================================================

-type otree() :: aeu_mtrees:tree().
-type query() :: aeo_query:query().
-type oracle() :: aeo_oracles:oracle().
-type cache_item() :: {oracle, aeo_oracles:id()}
                    | {query, aeo_oracles:id(), aeo_query:id()}.
-type cache() :: gb_sets:set({integer(), cache_item()}).
-type block_height() :: non_neg_integer().

-record(oracle_tree, { otree  = aeu_mtrees:empty() :: otree()
                     , cache  = cache_new()        :: cache()
                     }).

-opaque tree() :: #oracle_tree{}.

-export_type([ tree/0
             ]).

-define(HASH_SIZE, 32).

%%%===================================================================
%%% API
%%%===================================================================

-spec empty() -> tree().
empty() ->
    OTree  = aeu_mtrees:empty(),
    #oracle_tree{ otree  = OTree
                , cache  = cache_new()
                }.

-spec empty_with_backend() -> tree().
empty_with_backend() ->
    OTree  = aeu_mtrees:empty_with_backend(aec_db_backends:oracles_backend()),
    #oracle_tree{ otree  = OTree
                , cache  = cache_new()
                }.


-spec prune(block_height(), tree()) -> tree().
prune(Height, #oracle_tree{} = Tree) ->
    %% TODO: We need to know what we pruned as well
    %% Oracle information should be around for the expiry block
    %% since we prune before the block, use Height - 1 for pruning.
    int_prune(Height - 1, Tree).

-spec enter_query(query(), tree()) -> tree().
enter_query(I, Tree) ->
    add_query(enter, I, Tree).

-spec insert_query(query(), tree()) -> tree().
insert_query(I, Tree) ->
    add_query(insert, I, Tree).

-spec get_query(aeo_oracles:id(), aeo_query:id(), tree()) -> query().
get_query(OracleId, Id, Tree) ->
    TreeId = <<OracleId/binary, Id/binary>>,
    Serialized = aeu_mtrees:get(TreeId, Tree#oracle_tree.otree),
    aeo_query:deserialize(Serialized).

-spec lookup_query(aeo_oracles:id(), aeo_query:id(), tree()) ->
                                                {'value', query()} | none.
lookup_query(OracleId, Id, Tree) ->
    TreeId = <<OracleId/binary, Id/binary>>,
    case aeu_mtrees:lookup(TreeId, Tree#oracle_tree.otree) of
        {value, Val} -> {value, aeo_query:deserialize(Val)};
        none -> none
    end.

-spec insert_oracle(oracle(), tree()) -> tree().
insert_oracle(O, Tree) ->
    Id = aeo_oracles:id(O),
    Serialized = aeo_oracles:serialize(O),
    Expires = aeo_oracles:expires(O),

    OTree  = aeu_mtrees:insert(Id, Serialized, Tree#oracle_tree.otree),
    Cache  = cache_push({oracle, Id}, Expires, Tree#oracle_tree.cache),
    Tree#oracle_tree{ otree  = OTree
                    , cache  = Cache
                    }.

-spec get_oracle(binary(), tree()) -> oracle().
get_oracle(Id, Tree) ->
    aeo_oracles:deserialize(aeu_mtrees:get(Id, Tree#oracle_tree.otree)).

-spec get_oracle_query_ids(binary(), tree()) -> [aeo_query:id()].
get_oracle_query_ids(Id, Tree) ->
    find_oracle_query_ids(Id, Tree).

-spec lookup_oracle(binary(), tree()) -> {'value', oracle()} | 'none'.
lookup_oracle(Id, Tree) ->
    case aeu_mtrees:lookup(Id, Tree#oracle_tree.otree) of
        {value, Val}  -> {value, aeo_oracles:deserialize(Val)};
        none -> none
    end.

-spec root_hash(tree()) -> {ok, aeu_mtrees:root_hash()} | {error, empty}.
root_hash(#oracle_tree{otree = OTree}) ->
    aeu_mtrees:root_hash(OTree).

-ifdef(TEST).
-spec oracle_list(tree()) -> list(oracle()).
oracle_list(#oracle_tree{otree = OTree}) ->
    [ aeo_oracles:deserialize(Val)
      || {Key, Val} <- aeu_mtrees:to_list(OTree),
         byte_size(Key) =:= 65
    ].

-spec query_list(tree()) -> list(query()).
query_list(#oracle_tree{otree = OTree}) ->
    [ aeo_query:deserialize(Val)
      || {Key, Val} <- aeu_mtrees:to_list(OTree),
         byte_size(Key) > 65
    ].
-endif.

-spec commit_to_db(tree()) -> tree().
commit_to_db(#oracle_tree{otree = OTree} = Tree) ->
    Tree#oracle_tree{otree = aeu_mtrees:commit_to_db(OTree)}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

add_query(How, I, #oracle_tree{otree = OTree} = Tree) ->
    OracleId    = aeo_query:oracle_address(I),
    Id          = aeo_query:id(I),
    TreeId      = <<OracleId/binary, Id/binary>>,
    SerializedI = aeo_query:serialize(I),
    Expires     = aeo_query:expires(I),
    OTree1      = case How of
                      enter  -> aeu_mtrees:enter(TreeId, SerializedI, OTree);
                      insert -> aeu_mtrees:insert(TreeId, SerializedI, OTree)
                  end,
    Cache  = cache_push({query, OracleId, Id}, Expires, Tree#oracle_tree.cache),
    Tree#oracle_tree{ otree  = OTree1
                    , cache  = Cache
                    }.

int_prune(Height, #oracle_tree{ cache = Cache } = Tree) ->
    int_prune(cache_safe_peek(Cache), Height, Tree).

int_prune(none, _Height, Tree) ->
    Tree;
int_prune({Height, Id}, Height, #oracle_tree{ cache = Cache } = Tree) ->
    {{Height, Id}, Cache1} = cache_pop(Cache),
    Tree1 = delete(Id, Tree#oracle_tree{ cache = Cache1 }),
    int_prune(cache_safe_peek(Cache1), Height, Tree1);
int_prune({Height1,_Id}, Height2, Tree) when Height2 < Height1 ->
    Tree.

delete({oracle, Id}, Tree) ->
    TreeIds = find_oracle_query_tree_ids(Id, Tree),
    OTree = int_delete([Id|TreeIds], Tree#oracle_tree.otree),
    Tree#oracle_tree{ otree = OTree};
delete({query, OracleId, Id}, Tree) ->
    TreeId = <<OracleId/binary, Id/binary>>,
    Otree = aeu_mtrees:delete(TreeId, Tree#oracle_tree.otree),
    Tree#oracle_tree{otree = Otree}.

int_delete([Id|Left], OTree) ->
    int_delete(Left, aeu_mtrees:delete(Id, OTree));
int_delete([], OTree) ->
    OTree.

%%%===================================================================
%%% Iterator for finding all oracle queries
%%%===================================================================

find_oracle_query_tree_ids(OracleId, Tree) ->
    find_oracle_query_ids(OracleId, Tree, tree).

find_oracle_query_ids(OracleId, Tree) ->
    find_oracle_query_ids(OracleId, Tree, id).


find_oracle_query_ids(OracleId, #oracle_tree{otree = T}, Type) ->
    Iterator = aeu_mtrees:iterator_from(OracleId, T),
    Next = aeu_mtrees:iterator_next(Iterator),
    find_oracle_query_ids(OracleId, Next, Type, []).

find_oracle_query_ids(_OracleId, '$end_of_table',_Type, Acc) ->
    Acc;
find_oracle_query_ids(OracleId, {Key,_Val, Iter}, Type, Acc) ->
    S = byte_size(OracleId),
    case Key of
        <<OracleId:S/binary, Id/binary>> ->
            NewAcc = case Type of
                         tree -> [Key|Acc];
                         id   -> [Id|Acc]
                     end,
            Next = aeu_mtrees:iterator_next(Iter),
            find_oracle_query_ids(OracleId, Next, Type, NewAcc);
        _ ->
            Acc
    end.

%%%===================================================================
%%% TTL Cache
%%%===================================================================

cache_new() ->
    gb_sets:empty().

cache_push(Id, Expires, C) ->
    gb_sets:add({Expires, Id}, C).

cache_safe_peek(C) ->
    case gb_sets:is_empty(C) of
        true  -> none;
        false -> gb_sets:smallest(C)
    end.

cache_pop(C) ->
    gb_sets:take_smallest(C).
