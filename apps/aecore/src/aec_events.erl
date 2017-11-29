%%%=============================================================================
%%% @copyright 2017, Aeternity Anstalt
%%% @doc
%%%    Event publish/subscribe support
%%% @end
%%%=============================================================================
-module(aec_events).

-export([publish/2,
         subscribe/1,
         unsubscribe/1]).

-import(aeu_debug, [pp/1]).

-export_type([event/0]).

-include("common.hrl").
-include("blocks.hrl").

-type event() :: block_created
               | block_received
               | mining_preempted
               | start_mining
               | tx_created
               | tx_received
               | chain_sync
               | mempool_sync.

-spec publish(event(), any()) -> ok.
publish(Event, Info) ->
    Data = #{sender => self(),
             time => os:timestamp(),
             info => Info},
    Res = gproc_ps:publish(l, Event, Data),
    lager:debug("publish(~p, ~p)", [Event, pp(Data)]),
    Res.

-spec subscribe(event()) -> true.
subscribe(Event) ->
    Res = gproc_ps:subscribe(l, Event),
    lager:debug("subscribe(~p)", [Event]),
    Res.

-spec unsubscribe(event()) -> true.
unsubscribe(Event) ->
    Res = gproc_ps:unsubscribe(l, Event),
    lager:debug("unsubscribe(~p)", [Event]),
    Res.

