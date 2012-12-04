%%------------------------------------------------------------------------------
%% Copyright 2012 FlowForwarding.org
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%-----------------------------------------------------------------------------

%% @author Erlang Solutions Ltd. <openflow@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc Module for handling per-flow meters.
-module(linc_us4_meter).

-behaviour(gen_server).

%% API
-export([modify/1,
         apply/2,
         update_flow_count/2,
         get_stats/1,
         get_config/1,
         get_features/0,
         is_valid/1]).

%% Internal API
-export([start/1,
         stop/1,
         start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("linc/include/linc.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include("linc_us4.hrl").

-define(SUPPORTED_BANDS, [drop,
                          dscp_remark,
                          experimenter]).
-define(SUPPORTED_FLAGS, [%% burst,
                          kbps,
                          pktps,
                          stats]).

-record(linc_meter_band, {
          type :: drop | dscp_remark | experimenter,
          rate :: integer(),
          prec_level :: integer() | undefined,
          experimenter :: integer() | undefined,
          pkt_count = 0 :: integer(),
          byte_count = 0 :: integer()
         }).

-record(linc_meter, {
          id :: integer(),
          rate_value :: kbps | pktps | {burst, kbps | pktps},
          stats = true :: boolean(),
          bands = [] :: [#linc_meter_band{}],
          flow_count = 0 :: integer(),
          pkt_count = 0 :: integer(),
          byte_count = 0 :: integer(),
          install_ts = now() :: {integer(), integer(), integer()}
         }).

-define(ETS, linc_meters).
-define(SUP, linc_us4_meter_sup).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

%% @doc Add, modify or delete a meter.
-spec modify(#ofp_meter_mod{}) -> noreply |
                                  {reply, Reply :: ofp_message_body()}.
modify(#ofp_meter_mod{command = add, meter_id = Id} = MeterMod) ->
    case get_meter_pid(Id) of
        undefined ->
            case start(MeterMod) of
                {ok, _Pid} ->
                    noreply;
                {error, Code} ->
                    {reply, error_msg(Code)}
            end;
        _Pid ->
            {reply, error_msg(meter_exists)}
    end;
modify(#ofp_meter_mod{command = modify, meter_id = Id} = MeterMod) ->
    case get_meter_pid(Id) of
        undefined ->
            {reply, error_msg(unknown_meter)};
        Pid ->
            case start(MeterMod) of
                {ok, _NewPid} ->
                    stop(Pid),
                    noreply;
                {error, Code} ->
                    {reply, error_msg(Code)}
            end
    end;
modify(#ofp_meter_mod{command = delete, meter_id = Id}) ->
    linc_us4_flow:delete_where_meter(Id),
    case get_meter_pid(Id) of
        undefined ->
            ok;
        Pid ->
            stop(Pid)
    end,
    noreply.

%% @doc Update flow entry count associated with a meter.
-spec update_flow_count(integer(), integer()) -> any().
update_flow_count(Id, Incr) ->
    case get_meter_pid(Id) of
        undefined ->
            ?DEBUG("Updating flow count of an non existing meter ~p", [Id]);
        Pid ->
            gen_server:cast(Pid, {update_flow_count, Incr})
    end.

%% @doc Apply meter to a packet.
-spec apply(integer(), #ofs_pkt{}) -> {continue, NewPkt :: #ofs_pkt{}} | drop.
apply(Id, Pkt) ->
    case get_meter_pid(Id) of
        undefined ->
            ?DEBUG("Applying non existing meter ~p", [Id]),
            drop;
        Pid ->
            gen_server:call(Pid, {apply, Pkt})
    end.

%% @doc Get meter statistics.
-spec get_stats(integer() | all) -> Reply :: #ofp_meter_stats_reply{}.
get_stats(all) ->
    Meters = [gen_server:call(Pid, get_state)
              || {_, Pid} <- lists:keysort(1, ets:tab2list(?ETS))],
    #ofp_meter_stats_reply{body = [export_stats(Meter) || Meter <- Meters]};
get_stats(Id) when is_integer(Id) ->
    case get_meter_pid(Id) of
        undefined ->
            #ofp_meter_stats_reply{body = []};
        Pid ->
            Meter = gen_server:call(Pid, get_state),
            #ofp_meter_stats_reply{body = [export_stats(Meter)]}
    end.

%% @doc Get meter configuration.
-spec get_config(integer() | all) -> Reply :: #ofp_meter_config_reply{}.
get_config(all) ->
    Meters = [gen_server:call(Pid, get_state)
              || {_, Pid} <- lists:keysort(1, ets:tab2list(?ETS))],
    #ofp_meter_config_reply{body = [export_meter(Meter) || Meter <- Meters]};
get_config(Id) when is_integer(Id)  ->
    case get_meter_pid(Id) of
        undefined ->
            #ofp_meter_config_reply{body = []};
        Pid ->
            Meter = gen_server:call(Pid, get_state),
            #ofp_meter_config_reply{body = [export_meter(Meter)]}
    end.

%% @doc Get meter features.
-spec get_features() -> Reply :: #ofp_meter_features_reply{}.
get_features() ->
    #ofp_meter_features_reply{max_meter = ?MAX,
                              band_types = ?SUPPORTED_BANDS,
                              capabilities = ?SUPPORTED_FLAGS,
                              max_bands = ?MAX,
                              max_color = 0}.

%% @doc Check if meter with a given id exists.
-spec is_valid(integer()) -> boolean().
is_valid(Id) ->
    case get_meter_pid(Id) of
        undefined ->
            false;
        _Else ->
            true
    end.

%%------------------------------------------------------------------------------
%% Internal API functions
%%------------------------------------------------------------------------------

start(MeterMod) ->
    supervisor:start_child(?SUP, [MeterMod]).

stop(Pid) ->
    supervisor:terminate_child(?SUP, Pid).

start_link(MeterMod) ->
    gen_server:start_link(?MODULE, [MeterMod], []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([#ofp_meter_mod{meter_id = Id} = MeterMod]) ->
    process_flag(trap_exit, true),
    case import_meter(MeterMod) of
        {ok, State} ->
            ets:insert(?ETS, {Id, self()}),
            {ok, State};
        {error, Code} ->
            {stop, Code}
    end.

handle_call({apply, Pkt}, _From, #linc_meter{rate_value = Value,
                                             pkt_count = Pkts,
                                             byte_count = Bytes,
                                             install_ts = Then,
                                             bands = Bands} = State) ->
    NewPkts = Pkts + 1,
    NewBytes = Bytes + Pkt#ofs_pkt.size,
    Seconds = timer:now_diff(now(), Then) div 1000000 + 1,
    Rate = case Value of
               kbps ->
                   ((NewBytes * 8) div 1000) / Seconds;
               pktps ->
                   NewPkts / Seconds
               %% TODO:
               %% {burst, kbps} ->
               %%     todo;
               %% {burst, pktps} ->
               %%     todo
           end,
    {Reply, NewBands} = apply_band(Rate, Pkt, Bands),
    {reply, Reply, State#linc_meter{pkt_count = NewPkts,
                                    byte_count = NewBytes,
                                    bands = NewBands}};
handle_call(get_state, _From, State) ->
    {reply, State, State}.

handle_cast({update_flow_count, Incr},
            #linc_meter{flow_count = Flows} = State) ->
    {noreply, State#linc_meter{flow_count = Flows + Incr}}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #linc_meter{id = Id}) ->
    ets:delete_object(?ETS, {Id, self()}),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

apply_band(Rate, Pkt, Bands) ->
    case find_the_right_band(Rate, Bands) of
        false ->
            {{continue, Pkt}, Bands};
        N ->
            R = case lists:nth(N, Bands) of
                    #linc_meter_band{type = drop} ->
                        drop;
                    #linc_meter_band{type = dscp_remark,
                                     prec_level = _Prec} ->
                        %% TODO:
                        %% NewPkt = linc_us4_packet:descrement_dscp(Pkt, Prec),
                        NewPkt = Pkt,
                        {continue, NewPkt};
                    #linc_meter_band{type = experimenter,
                                     experimenter = _ExperimenterId} ->
                        %%
                        %% Put your EXPERIMENTER band code here
                        %%
                        {continue, Pkt}
                end,
            {R, update_band(N, Bands, Pkt#ofs_pkt.size)}
    end.

find_the_right_band(Rate, Bands) ->
    F = fun(Band, {HRate, HighN, N}) ->
                BRate = Band#linc_meter_band.rate,
                case Rate > BRate andalso BRate > HRate of
                    true ->
                        {BRate, N, N + 1};
                    false ->
                        {HRate, HighN, N + 1}
                end
        end,
    case lists:foldl(F, {-1, 0, 1}, Bands) of
        {-1, 0, _} ->
            false;
        {_, N, _} ->
            N
    end.

update_band(1, [Band | Bands], NewBytes) ->
    #linc_meter_band{pkt_count = Pkts,
                     byte_count = Bytes} = Band,
    [Band#linc_meter_band{pkt_count = Pkts + 1,
                          byte_count = Bytes + NewBytes} | Bands];
update_band(N, [Band | Bands], Bytes) ->
    [Band | update_band(N - 1, Bands, Bytes)].

import_meter(#ofp_meter_mod{meter_id = Id,
                            flags = Flags,
                            bands = Bands}) ->
    case import_flags(Flags) of
        {true, {Value, Stats}} ->
            NewBands = [import_band(Value, Band) || Band <- Bands],
            case lists:any(fun(X) -> X == error end, NewBands) of
                false ->
                    NewMeter = #linc_meter{id = Id,
                                           rate_value = Value,
                                           stats = Stats,
                                           bands = NewBands},
                    {ok, NewMeter};
                true ->
                    {error, bad_band}
            end;
        false ->
            {error, bad_flags}
    end.

import_flags(Flags) ->
    SortFlags = lists:usort(Flags),
    case ordsets:is_subset(SortFlags, ?SUPPORTED_FLAGS)
        andalso not ordsets:is_subset([kbps, pktps], SortFlags) of
        true ->
            Value = case lists:member(pktps, Flags) of
                        true ->
                            pktps;
                        false ->
                            kbps
                    end,
            Value2 = case lists:member(burst, Flags) of
                         true ->
                             {burst, Value};
                         false ->
                             Value
                     end,
            {true, {Value2, lists:member(stats, Flags)}};
        false ->
            false
    end.

import_band(Value, #ofp_meter_band_drop{rate = Rate,
                                        burst_size = Burst}) ->
    case lists:member(drop, ?SUPPORTED_BANDS) of
        true ->
            #linc_meter_band{type = drop,
                             rate = case Value of
                                        {burst, _} ->
                                            Burst;
                                        _Else ->
                                            Rate
                                    end};
        false ->
            error
    end;
import_band(Value, #ofp_meter_band_dscp_remark{rate = Rate,
                                               burst_size = Burst,
                                               prec_level = Prec}) ->
    case lists:member(dscp_remark, ?SUPPORTED_BANDS) of
        true ->
            #linc_meter_band{type = dscp_remark,
                             rate = case Value of
                                        {burst, _} ->
                                            Burst;
                                        _Else ->
                                            Rate
                                    end,
                             prec_level = Prec};
        false ->
            error
    end;
import_band(Value, #ofp_meter_band_experimenter{rate = Rate,
                                                burst_size = Burst,
                                                experimenter = Exp}) ->
    case lists:member(experimenter, ?SUPPORTED_BANDS) of
        true ->
            #linc_meter_band{type = experimenter,
                             rate = case Value of
                                        {burst, _} ->
                                            Burst;
                                        _Else ->
                                            Rate
                                    end,
                             experimenter = Exp};
        false ->
            error
    end;
import_band(_, _) ->
    error.

export_stats(#linc_meter{id = Id,
                         stats = StatsEnabled,
                         bands = Bands,
                         install_ts = Then} = Meter) ->
    BandStats = [export_band_stats(StatsEnabled, Band) || Band <- Bands],
    MicroDuration = timer:now_diff(now(), Then),
    {Flows, Pkts, Bytes} = case StatsEnabled of
                               true ->
                                   #linc_meter{flow_count = F,
                                               pkt_count = P,
                                               byte_count = B} = Meter,
                                   {F, P, B};
                               false ->
                                   {-1, -1, -1}
                           end,
    #ofp_meter_stats{meter_id = Id,
                     flow_count = Flows,
                     packet_in_count = Pkts,
                     byte_in_count = Bytes,
                     duration_sec = MicroDuration div 1000000,
                     duration_nsec = MicroDuration * 1000,
                     band_stats = BandStats}.

export_band_stats(true, #linc_meter_band{pkt_count = Pkts,
                                         byte_count = Bytes}) ->
    #ofp_meter_band_stats{packet_band_count = Pkts,
                          byte_band_count = Bytes};
export_band_stats(false, _Band) ->
    #ofp_meter_band_stats{packet_band_count = -1,
                          byte_band_count = -1}.

export_meter(#linc_meter{id = Id,
                         rate_value = Value,
                         stats = Stats,
                         bands = Bands}) ->
    NewBands = [export_band(Value, Band) || Band <- Bands],
    #ofp_meter_config{flags = export_flags(Value, Stats),
                      meter_id = Id,
                      bands = NewBands}.

export_band(Value, #linc_meter_band{type = Type,
                                    rate = MyRate,
                                    prec_level = Prec,
                                    experimenter = Exp}) ->
    {Rate, Burst} = export_values(Value, MyRate),
    case Type of
        drop ->
            #ofp_meter_band_drop{type = Type,
                                 rate = Rate,
                                 burst_size = Burst};
        dscp_remark ->
            #ofp_meter_band_dscp_remark{type = Type,
                                        rate = Rate,
                                        burst_size = Burst,
                                        prec_level = Prec};
        experimenter ->
            #ofp_meter_band_experimenter{type = Type,
                                         rate = Rate,
                                         burst_size = Burst,
                                         experimenter = Exp}
    end.

export_flags({burst, Value}, true) ->
    [Value, burst, stats];
export_flags({burst, Value}, false) ->
    [Value, burst];
export_flags(Value, true) ->
    [Value, stats];
export_flags(Value, false) ->
    [Value].

export_values({burst, _}, Rate) ->
    {-1, Rate};
export_values(_Else, Rate) ->
    {Rate, -1}.

get_meter_pid(Id) ->
    case ets:lookup(?ETS, Id) of
        [] ->
            undefined;
        [{Id, Pid}] ->
            Pid
    end.

error_msg(Code) ->
    #ofp_error_msg{type = meter_mod_failed,
                   code = Code}.
