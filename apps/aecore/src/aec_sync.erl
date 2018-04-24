%%%=============================================================================
%%% @copyright 2017, Aeternity Anstalt
%%% @doc
%%%    Module storing peers list and providing funtions for peer interaction
%%% @end
%%%=============================================================================
-module(aec_sync).

-include("common.hrl").
-include("blocks.hrl").

-behaviour(gen_server).

-import(aeu_debug, [pp/1]).
-import(aec_peers, [ppp/1]).

%% API
-export([start_link/0]).

%% API called from strongly connected component aec_peers
-export([schedule_ping/1]).

-export([start_sync/3, fetch_mempool/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3]).

-ifdef(TEST).
-compile([export_all, nowarn_export_all]).
-endif.

-define(MAX_HEADERS_PER_CHUNK, 100).

%%%=============================================================================
%%% API
%%%=============================================================================

start_sync(PeerId, RemoteHash, RemoteDifficulty) ->
    gen_server:cast(?MODULE, {start_sync, PeerId, RemoteHash, RemoteDifficulty}).

fetch_mempool(PeerId) ->
    gen_server:cast(?MODULE, {fetch_mempool, PeerId}).

schedule_ping(PeerId) ->
    gen_server:cast(?MODULE, {schedule_ping, PeerId}).

sync_in_progress(PeerId) ->
    gen_server:call(?MODULE, {sync_in_progress, PeerId}).

known_chain(Chain, ExtraInfo) ->
    gen_server:call(?MODULE, {known_chain, Chain, ExtraInfo}).

update_sync_task(Update, Task) ->
    gen_server:call(?MODULE, {update_sync_task, Update, Task}).

next_work_item(Task, LastResult) ->
    gen_server:call(?MODULE, {next_work_item, Task, LastResult}).

handle_worker(Task, Action) ->
    gen_server:cast(?MODULE, {handle_worker, Task, Action}).

%%%=============================================================================
%%% gen_server functions
%%%=============================================================================

%% When we Ping a node with at least as much difficulty as we have,
%% then we are going to sync with it.
%% We already agree upon the genesis block and need to find the highest common
%% block we agree upon. We use a binary search to find out.
%% From the height we agree upon, we start asking for blocks to add to the chain.
%%
%% When an additional Ping arrives for which we agree upon genesis, we have
%% the following possibilities:
%% 1. It has worst top hash than our node, do not include in sync
%% 2. It has better top hash than our node
%%    We binary search for a block that we agree upon (could be genesis)
%% We add new node to sync pool to sync agreed block upto top of new
%% 1. If we are already synchronizing, we ignore it,
%%    the ongoing sync will pick that up later
%% 2. If we are not already synchronizing, we start doing so.
%%
%% We sync with several nodes at the same time and use as strategy
%% to pick a random hash from the hashes in the pool.

-record(state, {sync_tasks = []}).
-record(sync_task, {id, chain, pool = [], agreed,
                    adding = [], pending = [], workers = []}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    aec_events:subscribe(block_created),
    aec_events:subscribe(top_changed),
    aec_events:subscribe(tx_created),

    Peers = parse_peers(aeu_env:user_map_or_env(<<"peers">>, aecore, peers, [])),
    BlockedPeers = parse_peers(aeu_env:user_map_or_env(<<"blocked_peers">>, aecore, blocked_peers, [])),

    [aec_peers:block_peer(P) || P <- BlockedPeers],
    aec_peers:add_and_ping_peers(Peers, true),

    erlang:process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call({sync_in_progress, PeerId}, _, State) ->
    {reply, peer_in_sync(State, PeerId), State};
handle_call({known_chain, Chain0 = #{ chain_id := CId0 }, NewChainInfo}, _From, State0) ->
    {Chain, State} =
        case NewChainInfo of
            none ->
                {Chain0, State0};
            #{ chain_id := CId1 } when CId1 == CId0 ->
                {merge_chains(Chain0, NewChainInfo), State0};
            #{ chain_id := _CId } ->
                {Chain0, add_chain_info(NewChainInfo, State0)}
        end,
    {Res, State1} = sync_task_for_chain(Chain, State),
    {reply, Res, State1};
handle_call({update_sync_task, Update, STId}, _From, State) ->
    State1 =
        case get_sync_task(STId, State) of
            {ok, ST} ->
                ST1 = do_update_sync_task(Update, ST),
                case ST1#sync_task.chain of
                    #{ peers := [], chain := [Target | _] } ->
                        lager:info("Removing/ending sync task ~p target was ~p",
                                   [STId, Target]),
                        delete_sync_task(STId, State);
                    _ ->
                        set_sync_task(ST1, State)
                end;
            {error, not_found} ->
                lager:debug("SyncTask ~p not found", [STId]),
                State
        end,
    {reply, ok, State1};
handle_call({next_work_item, STId, LastResult}, _From, State) ->
    {Reply, State1} =
        case get_sync_task(STId, State) of
            {ok, ST} ->
                ST1 = handle_last_result(ST, LastResult),
                {Res, ST2} = get_next_work_item(ST1),
                {Res, set_sync_task(STId, ST2, State)};
            {error, not_found} ->
                {sync_task_done, State}
        end,
    {reply, Reply, State1};
handle_call(_, _From, State) ->
    {reply, error, State}.

handle_cast({start_sync, PeerId, RemoteHash, _RemoteDifficulty}, State) ->
    %% We could decide not to sync if we are already syncing, but that
    %% opens up for an attack in which someone fakes to have higher difficulty
    run_job(sync_task_workers, fun() -> do_start_sync(PeerId, RemoteHash) end),
    {noreply, State};
handle_cast({fetch_mempool, PeerId}, State) ->
    run_job(sync_mempool_workers, fun() -> do_fetch_mempool(PeerId) end),
    {noreply, State};
handle_cast({schedule_ping, PeerId}, State) ->
    case peer_in_sync(State, PeerId) of
        true ->
            ok;
        false ->
            run_job(sync_ping_workers, fun() -> ping_peer(PeerId) end)
    end,
    {noreply, State};
handle_cast({handle_worker, STId, Action}, State) ->
    State1 =
        case get_sync_task(STId, State) of
            {ok, ST} ->
                ST1 = do_handle_worker(Action, ST),
                set_sync_task(ST1, State);
            {error, not_found} ->
                State
        end,
    {noreply, State1};
handle_cast(_, State) ->
    {noreply, State}.

handle_info({gproc_ps_event, Event, #{info := Info}}, State) ->
    PeerIds = [ aec_peers:peer_id(P) || P <- aec_peers:get_random(all) ],
    NonSyncingPeerIds = [ P || P <- PeerIds, not peer_in_sync(State, P) ],
    case Event of
        block_created -> enqueue(block, Info, NonSyncingPeerIds);
        top_changed   -> enqueue(block, Info, NonSyncingPeerIds);
        tx_created    -> enqueue(tx, Info, NonSyncingPeerIds);
        tx_received   -> enqueue(tx, Info, NonSyncingPeerIds);
        _             -> ignore
    end,
    {noreply, State};
handle_info({'EXIT', Pid, Reason}, State) ->
    %% It might be one of our syncing workers that crashed
    if Reason =/= normal -> lager:info("worker stopped with reason: ~p", [Reason]);
       true -> ok
    end,
    {noreply, do_terminate_worker(Pid, State)};
handle_info(_, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_FromVsn, State, _Extra) ->
    {ok, State}.

sync_task_for_chain(Chain, S = #state{ sync_tasks = STs }) ->
    case match_tasks(Chain, STs, []) of
        no_match ->
            ST = init_sync_task(Chain),
            {{new, Chain, ST#sync_task.id}, set_sync_task(ST, S)};
        {match, ST = #sync_task{ id = STId, chain = C2 }} ->
            NewChain = merge_chains(Chain#{ chain_id := STId }, C2),
            ST1 = ST#sync_task{ chain = NewChain },
            {{existing, STId}, set_sync_task(ST1, S)};
        Res = {inconclusive, _, _} ->
            {Res, S}
    end.

handle_last_result(ST, none) ->
    ST;
handle_last_result(ST = #sync_task{ agreed = undefined }, {agreed_height, Agreed}) ->
    ST#sync_task{ agreed = Agreed };
handle_last_result(ST, {agreed_height, _Agreed}) ->
    ST;
handle_last_result(ST = #sync_task{ pool = [] }, {hash_pool, HashPool}) ->
    {Height, Hash, false} = lists:last(HashPool),
    ST#sync_task{ pool = HashPool, agreed = #{ height => Height, hash => Hash } };
handle_last_result(ST, {hash_pool, _HashPool}) ->
    ST;
handle_last_result(ST = #sync_task{ pool = Pool }, {get_block, Height, Hash, PeerId, {ok, Block}}) ->
    Pool1 = lists:keyreplace(Height, 1, Pool, {Height, Hash, {PeerId, Block}}),
    ST#sync_task{ pool = Pool1 };
handle_last_result(ST, {post_blocks, ok}) ->
    ST#sync_task{ adding = [] };
handle_last_result(ST = #sync_task{ adding = Add, pending = Pends, pool = Pool },
                  {post_blocks, {error, Height}}) ->
    [{Height, Hash, _} | PutBack] =
        lists:dropwhile(fun({H, _, _}) -> H < Height end, Add) ++ lists:append(Pends),
    ST#sync_task{ adding = [], pending = [], pool = [{Height, Hash, false} | PutBack] ++ Pool }.

split_pool(Pool) -> split_pool(Pool, []).

split_pool([{_, _, false} | _] = Pool, Acc) ->
    {lists:reverse(Acc), Pool};
split_pool([], Acc) ->
    {lists:reverse(Acc), []};
split_pool([X | Pool], Acc) ->
    split_pool(Pool, [X | Acc]).

get_next_work_item(ST = #sync_task{ adding = [], pending = [ToAdd | NewPending] }) ->
    {{post_blocks, ToAdd}, ST#sync_task{ adding = ToAdd, pending = NewPending }};
get_next_work_item(ST = #sync_task{ chain = Chain, agreed = undefined }) ->
    {{agree_on_height, Chain}, ST};
get_next_work_item(ST = #sync_task{ pool = [], agreed = #{ hash := LastAgreed } }) ->
    {{fill_pool, LastAgreed}, ST};
get_next_work_item(ST = #sync_task{ pool = [{_, _, {_, _}} | _] = Pool, adding = Add, pending = Pend }) ->
    {ToBeAdded, NewPool} = split_pool(Pool),
    case Add of
        [] ->
            {{post_blocks, ToBeAdded}, ST#sync_task{ pool = NewPool, adding = [ToBeAdded] }};
        _ when length(Pend) < 10 orelse NewPool /= [] ->
            get_next_work_item(ST#sync_task{ pool = NewPool, pending = Pend ++ [ToBeAdded] });
        _ ->
            {take_a_break, ST}
    end;
get_next_work_item(ST = #sync_task{ pool = [{_, _, false} | _] = Pool }) ->
    PickFrom = [ P || P = {_, _, false} <- Pool ],
    Random = rand:uniform(length(PickFrom)),
    {PickH, PickHash, false} = lists:nth(Random, PickFrom),
    lager:debug("Get block at height ~p", [PickH]),
    {{get_block, PickH, PickHash}, ST};
get_next_work_item(ST) ->
    lager:info("Nothing to do: ~p", [ST]),
    {take_a_break, ST}.

do_update_sync_task({done, PeerId}, ST = #sync_task{ chain = Chain }) ->
    Chain1 = Chain#{ peers := maps:get(peers, Chain) -- [PeerId] },
    ST#sync_task{ chain = Chain1 };
do_update_sync_task({error, PeerId}, ST = #sync_task{ chain = Chain }) ->
    Chain1 = Chain#{ peers := maps:get(peers, Chain) -- [PeerId] },
    ST#sync_task{ chain = Chain1 }.

get_sync_task(STId, #state{ sync_tasks = STs }) ->
    case lists:keyfind(STId, #sync_task.id, STs) of
        false -> {error, not_found};
        ST    -> {ok, ST}
    end.

set_sync_task(ST = #sync_task{ id = STId }, State) ->
    set_sync_task(STId, ST, State).

set_sync_task(STId, ST, S = #state{ sync_tasks = STs }) ->
    S#state{ sync_tasks = lists:keystore(STId, #sync_task.id, STs, ST) }.

delete_sync_task(STId, S = #state{ sync_tasks = STs }) ->
    S#state{ sync_tasks = lists:keydelete(STId, #sync_task.id, STs) }.

add_chain_info(Chain = #{ chain_id := CId }, S) ->
    {ok, ST = #sync_task{ chain = Chain2 }} = get_sync_task(CId, S),
    ST1 = ST#sync_task{ chain = merge_chains(Chain, Chain2) },
    set_sync_task(ST1, S).

init_sync_task(Chain) ->
    #sync_task{ id = maps:get(chain_id, Chain), chain = Chain }.

merge_chains(#{ chain_id := CId, peers := Ps1, chain := C1 },
             #{ chain_id := CId, peers := Ps2, chain := C2 }) ->
    %% We sort descending...
    Cmp = fun(#{ height := H1 }, #{ height := H2 }) -> H1 >= H2 end,
    #{ chain_id => CId, peers => lists:usort(Ps1 ++ Ps2),
       chain => lists:merge(Cmp, C1, C2) }.

match_tasks(_Chain, [], []) ->
    no_match;
match_tasks(Chain, [], Acc) ->
    {N, #{ chain_id := CId, peers := Peers }} = hd(lists:reverse(Acc)),
    {inconclusive, Chain, {get_header, CId, Peers, N}};
match_tasks(Chain1, [ST = #sync_task{ chain = Chain2 } | STs], Acc) ->
    case match_chains(maps:get(chain, Chain1), maps:get(chain, Chain2)) of
        equal     -> {match, ST};
        different -> match_tasks(Chain1, STs, Acc);
        {fst, N}  -> match_tasks(Chain1, STs, [{N, Chain1} | Acc]);
        {snd, N}  -> match_tasks(Chain1, STs, [{N, Chain2} | Acc])
    end.

match_chains([#{ height := N1 } | C1], [#{ height := N2 } | _] = C2) when N1 > N2 ->
    match_chains(C1, C2);
match_chains([#{ height := N1 } | _] = C1, [#{ height := N2 } | C2]) when N1 < N2 ->
    match_chains(C1, C2);
match_chains([], [#{ height := N } | _]) ->
    {snd, N};
match_chains([#{ height := N } | _], []) ->
    {fst, N};
match_chains([#{ hash := H } | _], [#{ hash := H } | _]) ->
    equal;
match_chains(_, _) ->
    different.

do_handle_worker({new_worker, PeerId, Pid}, ST = #sync_task{ workers = Ws }) ->
    case lists:keyfind(PeerId, 1, Ws) of
        false    -> ok;
        {_, Old} -> lager:info("Peer ~p already has a worker (~p)", [ppp(PeerId), Old])
    end,
    erlang:link(Pid),
    lager:debug("New worker ~p for peer ~p", [Pid, ppp(PeerId)]),
    ST#sync_task{ workers = lists:keystore(PeerId, 1, Ws, {PeerId, Pid}) };
do_handle_worker({change_worker, PeerId, OldPid, NewPid}, ST = #sync_task{ workers = Ws }) ->
    case lists:keyfind(PeerId, 1, Ws) of
        false ->
            lager:info("Missing worker ~p for peer ~p", [OldPid, ppp(PeerId)]);
        {_, OldPid} ->
            ok;
        {_, AnotherPid} ->
            lager:info("Wrong worker stored for peer ~p (~p)", [ppp(PeerId), AnotherPid])
    end,
    erlang:link(NewPid),
    %% The old worker will terminate right after the call to handle_worker so we can safely
    %% unlink it.
    erlang:unlink(OldPid),
    lager:debug("Update worker ~p (was ~p) for peer ~p", [NewPid, OldPid, ppp(PeerId)]),
    ST#sync_task{ workers = lists:keystore(PeerId, 1, Ws, {PeerId, NewPid}) }.

do_terminate_worker(Pid, S = #state{ sync_tasks = STs }) ->
    case [ ST || ST <- STs, lists:keyfind(Pid, 2, ST#sync_task.workers) /= false ] of
        [ST] ->
            set_sync_task(do_terminate_worker(Pid, ST), S);
        [] ->
            S
    end;
do_terminate_worker(Pid, ST = #sync_task{ workers = Ws }) ->
    {Peer, _} = lists:keyfind(Pid, 2, Ws),
    lager:debug("Terminating worker ~p for peer ~p", [Pid, ppp(Peer)]),
    ST#sync_task{ workers = lists:keydelete(Pid, 2, Ws) }.

%%%=============================================================================
%%% Jobs worker
%%%=============================================================================
delayed_run_job(PeerId, Task, Queue, Fun, Delay) ->
    OldWorker = self(),
    spawn(fun() -> NewWorker = self(),
                   handle_worker(Task, {change_worker, PeerId, OldWorker, NewWorker}),
                   timer:sleep(Delay),
                   jobs:run(Queue, Fun)
          end).

run_job(Queue, Fun) ->
    spawn(jobs, run, [Queue, Fun]).

%% Gossip Tx or Block - spawn a process and call jobs from there.
enqueue(Kind, Data, PeerIds) ->
    spawn(fun() ->
    case Kind of
        block ->
            [ jobs:run(sync_gossip_workers, fun() -> do_forward_block(Data, PId) end)
              || PId <- PeerIds ];
        tx ->
            [ jobs:run(sync_gossip_workers, fun() -> do_forward_tx(Data, PId) end)
              || PId <- PeerIds ]
    end end).

ping_peer(PeerId) ->
    Res = aec_peer_connection:ping(PeerId),
    lager:debug("Ping (~p): ~p", [ppp(PeerId), Res]),
    case Res of
        ok ->
            aec_peers:log_ping(PeerId, ok);
        {error, _} ->
            aec_peers:log_ping(PeerId, error)
    end.

do_forward_block(Block, PeerId) ->
    Res = aec_peer_connection:send_block(PeerId, Block),
    lager:debug("send_block to (~p): ~p", [ppp(PeerId), Res]).

do_forward_tx(Tx, PeerId) ->
    Res = aec_peer_connection:send_tx(PeerId, Tx),
    lager:debug("send_tx to (~p): ~p", [ppp(PeerId), Res]).

do_start_sync(PeerId, RemoteHash) ->
    case sync_in_progress(PeerId) of
        true ->
            lager:debug("Already syncing with ~p", [ppp(PeerId)]);
        false ->
           do_start_sync1(PeerId, RemoteHash)
    end.

do_start_sync1(PeerId, RemoteHash) ->
    case aec_peer_connection:get_header_by_hash(PeerId, RemoteHash) of
        {ok, Hdr} ->
            lager:debug("New header received (~p): ~p", [ppp(PeerId), pp(Hdr)]),

            %% We do try really hard to identify the same chain here...
            Chain = init_chain(PeerId, Hdr),
            case known_chain(Chain) of
                {ok, Task} ->
                    handle_worker(Task, {new_worker, PeerId, self()}),
                    do_work_on_sync_task(PeerId, Task);
                {error, Reason} ->
                    lager:info("Could not identify chain, aborting sync with ~p (~p)",
                               [ppp(PeerId), Reason])
            end;
        {error, Reason} ->
            lager:debug("fetching top block (~p) failed: ~p", [ppp(PeerId), Reason])
    end.

init_chain(PeerId, Header) ->
    init_chain(make_ref(), [PeerId], Header).

init_chain(ChainId, Peers, Header) ->
    {ok, Hash} = aec_headers:hash_header(Header),
    Height     = aec_headers:height(Header),
    PrevHash   = [ #{ height => Height - 1, hash => aec_headers:prev_hash(Header)} || Height > 1 ],
    #{ chain_id => ChainId, peers => Peers,
       chain => [#{ hash => Hash, height => Height }] ++ PrevHash }.

known_chain(Chain) ->
    identify_chain(known_chain(Chain, none)).

identify_chain({existing, Task}) ->
    lager:debug("Already syncing chain ~p", [Task]),
    {ok, Task};
identify_chain({new, #{ chain := [Target | _]}, Task}) ->
    lager:info("Starting new sync task ~p target is ~p", [Task, Target]),
    {ok, Task};
identify_chain({inconclusive, Chain, {get_header, CId, [PeerId | _] = Peers, N}}) -> %% TODO: use all peers
    case aec_peer_connection:get_header_by_height(PeerId, N) of
        {ok, Header} ->
            identify_chain(known_chain(Chain, init_chain(CId, Peers, Header)));
        {error, Reason} ->
            lager:debug("fetching header at height ~p from ~p failed: ~p",
                        [N, ppp(PeerId), Reason]),
            {error, Reason}
    end.

do_work_on_sync_task(PeerId, Task) ->
    do_work_on_sync_task(PeerId, Task, none).

do_work_on_sync_task(PeerId, Task, LastResult) ->
    %% lager:debug("working on ~p against ~p (Last: ~p)", [Task, ppp(PeerId), LastResult]),
    case next_work_item(Task, LastResult) of
        take_a_break ->
            delayed_run_job(PeerId, Task, sync_task_workers,
                            fun() -> do_work_on_sync_task(PeerId, Task) end, 250);
        {agree_on_height, Chain} ->
            #{ chain := [#{ hash := TopHash, height := TopHeight } | _] } = Chain,
            LocalHeader = aec_chain:top_header(),
            LocalHeight = aec_headers:height(LocalHeader),
            MinAgreedHash = aec_chain:genesis_hash(),
            MaxAgree = min(LocalHeight, TopHeight),
            {AHeight, AHash} =
                agree_on_height(PeerId, TopHash, TopHeight,
                                MaxAgree, MaxAgree, ?GENESIS_HEIGHT, MinAgreedHash),
            lager:debug("Agreed upon height (~p): ~p", [ppp(PeerId), AHeight]),
            do_work_on_sync_task(PeerId, Task, {agreed_height, #{ height => AHeight, hash => AHash }});
        {fill_pool, StartFrom} ->
            fill_pool(PeerId, StartFrom, Task);
        {post_blocks, Blocks} ->
            Res = post_blocks(Blocks),
            do_work_on_sync_task(PeerId, Task, {post_blocks, Res});
        {get_block, Height, Hash} ->
            Res =
                case do_fetch_block(PeerId, Hash) of
                    {ok, false, _Block} -> {get_block, Height, Hash, PeerId, {ok, local}};
                    {ok, true, Block}   -> {get_block, Height, Hash, PeerId, {ok, Block}};
                    {error, _}          -> none
            end,
            do_work_on_sync_task(PeerId, Task, Res)
    end.

post_blocks([]) -> ok;
post_blocks([{StartHeight, _, _} | _] = Blocks) ->
    post_blocks(StartHeight, StartHeight, Blocks).

post_blocks(From, To, []) ->
    lager:info("Synced blocks ~p - ~p", [From, To]),
    ok;
post_blocks(From, _To, [{Height, _Hash, {_PeerId, local}} | Blocks]) ->
    post_blocks(From, Height, Blocks);
post_blocks(From, To, [{Height, _Hash, {_PeerId, Block}} | Blocks]) ->
    case aec_conductor:add_synced_block(Block) of
        ok ->
            post_blocks(From, Height, Blocks);
        {error, Reason} ->
            lager:info("Failed to add synced block ~p: ~p", [Height, Reason]),
            lager:info("Synced blocks ~p - ~p", [From, To]),
            {error, Height}
    end.

%% Ping logic makes sure they always agree on genesis header (height 0)
%% We look for the block that is both on remote highest chain and in our local
%% chain connected to genesis (may be on a fork, but that fork has now more
%% difficulty than our highest chain (otherwise we would not sync).
%%
%% Invariant: AgreedHash is hash at height Min.
agree_on_height(_PeerId, _RHash, _RH, _LH, Min, Min, AgreedHash) ->
    {Min, AgreedHash};
agree_on_height(PeerId, RHash, RH, CheckHeight, Max, Min, AgreedHash) when RH == CheckHeight ->
    case aec_chain:hash_is_connected_to_genesis(RHash) of
        true ->
             %% We agree on a block
             Middle = (Max + RH) div 2,
             case Min < Middle andalso Middle < Max of
               true ->
                   agree_on_height(PeerId, RHash, RH, Middle, Max, RH, RHash);
               false ->
                   {RH, RHash}
             end;
        false ->
             %% We disagree. Local on a fork compared to remote. Check half-way
             Middle = (Min + RH) div 2,
             case Min < Middle andalso Middle < Max of
                 true ->
                     agree_on_height(PeerId, RHash, RH, Middle, RH, Min, AgreedHash);
                 false ->
                     {Min, AgreedHash}
             end
    end;
agree_on_height(PeerId, _, RH, CheckHeight, Max, Min, AgreedHash) when RH =/= CheckHeight ->
    case aec_peer_connection:get_header_by_height(PeerId, CheckHeight) of
         {ok, RemoteAtHeight} ->
             {ok, RHash} = aec_headers:hash_header(RemoteAtHeight),
             lager:debug("New header received (~p): ~p", [ppp(PeerId), pp(RemoteAtHeight)]),
             agree_on_height(PeerId, RHash, CheckHeight, CheckHeight, Max, Min, AgreedHash);
         {error, Reason} ->
             lager:debug("Fetching header ~p from ~p failed: ~p", [CheckHeight, ppp(PeerId), Reason]),
             {Min, AgreedHash}
    end.

fill_pool(PeerId, AgreedHash, ST) ->
    case aec_peer_connection:get_n_successors(PeerId, AgreedHash, ?MAX_HEADERS_PER_CHUNK) of
        {ok, []} ->
            update_sync_task({done, PeerId}, ST),
            lager:info("Sync done (according to ~p)", [ppp(PeerId)]),
            aec_events:publish(chain_sync, {chain_sync_done, PeerId});
        {ok, Hashes} ->
            HashPool = [ {Height, Hash, false} || {Height, Hash} <- Hashes ],
            %% lager:debug("We need to get the following hashes: [~p, ... ~p] ",
            %%             [hd(HashPool), lists:last(HashPool)]),
            do_work_on_sync_task(PeerId, ST, {hash_pool, HashPool});
        {error, _} = Error ->
            lager:info("Abort sync with ~p (~p) ", [ppp(PeerId), Error]),
            update_sync_task({error, PeerId}, ST),
            {error, sync_abort}
    end.

do_fetch_block(PeerId, Hash) ->
    case aec_chain:get_block(Hash) of
        {ok, Block} ->
            lager:debug("block ~p already fetched, using local copy", [pp(Hash)]),
            {ok, false, Block};
        error ->
            do_fetch_block_ext(Hash, PeerId)
    end.

do_fetch_block_ext(Hash, PeerId) ->
    lager:debug("we don't have the block -fetching (~p)", [pp(Hash)]),
    case aec_peer_connection:get_block(PeerId, Hash) of
        {ok, Block} ->
            case header_hash(Block) =:= Hash of
                true ->
                    lager:debug("block fetched from ~p (~p); ~p",
                                [ppp(PeerId), pp(Hash), pp(Block)]),
                    {ok, true, Block};
                false ->
                    {error, hash_mismatch}
            end;
        {error, _} = Error ->
            lager:debug("failed to fetch block from ~p; Hash = ~p; Error = ~p",
                        [ppp(PeerId), pp(Hash), Error]),
            Error
    end.

do_fetch_mempool(PeerId) ->
    case aec_peer_connection:get_mempool(PeerId) of
        {ok, Txs} ->
            lager:debug("Mempool (~p) received, size: ~p",
                        [ppp(PeerId), length(Txs)]),
            aec_tx_pool:push(Txs),
            aec_events:publish(mempool_sync, {fetched, PeerId});
        Other ->
            lager:debug("Error fetching mempool from ~p: ~p",
                        [ppp(PeerId), Other]),
            aec_events:publish(mempool_sync, {error, Other, PeerId}),
            Other
    end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

header_hash(Block) ->
    Header = aec_blocks:to_header(Block),
    {ok, HeaderHash} = aec_headers:hash_header(Header),
    HeaderHash.

parse_peers(Ps) ->
    lists:append([ parse_peer(P) || P <- Ps ]).

parse_peer(P) ->
    case aec_peers:parse_peer_address(P) of
        {ok, PInfo} ->
            [PInfo];
        {error, _} ->
            []
    end.

peer_in_sync(#state{ sync_tasks = STs }, PeerId) ->
    lists:member(PeerId, lists:append([ Ps || #sync_task{ chain = #{ peers := Ps } } <- STs ])).

