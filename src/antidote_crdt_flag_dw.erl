%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc
%% An operation-based Disable-wins Flag CRDT.

%% @end
-module(antidote_crdt_flag_dw).

%% Callbacks
-export([ new/0,
          value/1,
          downstream/2,
          update/2,
          equal/2,
          to_binary/1,
          from_binary/1,
          is_operation/1,
          is_bottom/1,
          require_state_downstream/1,
          can_compress/2,
          compress/2
        ]).

-behaviour(antidote_crdt).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(TAG, 77).
-define(V1_VERS, 1).

-export_type([flag_dw/0]).
-opaque flag_dw() :: {antidote_crdt_flag:tokens(), antidote_crdt_flag:tokens()}.

%% SeenTokens, NewEnableTokens, NewDisableTokens
-type downstream_op() :: {antidote_crdt_flag:tokens(), antidote_crdt_flag:tokens(), antidote_crdt_flag:tokens()}.

-spec new() -> flag_dw().
new() ->
  {[], []}.

-spec value(flag_dw()) -> boolean().
value({EnableTokens, DisableTokens}) ->
  DisableTokens == [] andalso EnableTokens =/= [].

-spec downstream(antidote_crdt_flag:op(), flag_dw()) -> {ok, downstream_op()}.
downstream({disable, {}}, {EnableTokens, DisableTokens}) ->
  {ok, {EnableTokens ++ DisableTokens, [], [antidote_crdt_flag:unique()]}};
downstream({enable, {}}, {EnableTokens, DisableTokens}) ->
  {ok, {EnableTokens ++ DisableTokens, [antidote_crdt_flag:unique()], []}};
downstream({reset, {}}, {EnableTokens, DisableTokens}) ->
  {ok, {EnableTokens ++ DisableTokens, [], []}}.

-spec update(downstream_op(), flag_dw()) -> {ok, flag_dw()}.
  update({SeenTokens, NewEnableTokens, NewDisableTokens}, {CurrentEnableTokens, CurrentDisableTokens}) ->
    FinalEnableTokens = (CurrentEnableTokens ++ NewEnableTokens) -- SeenTokens,
    FinalDisableTokens = (CurrentDisableTokens ++ NewDisableTokens) -- SeenTokens,
    {ok, {FinalEnableTokens, FinalDisableTokens}}.

-spec equal(flag_dw(), flag_dw()) -> boolean().
  equal(Flag1, Flag2) ->
    Flag1 == Flag2.

-spec to_binary(flag_dw()) -> antidote_crdt_flag:binary_flag().
  to_binary(Flag) ->
    %% @TODO something smarter
    <<?TAG:8/integer, ?V1_VERS:8/integer, (term_to_binary(Flag))/binary>>.

from_binary(<<?TAG:8/integer, ?V1_VERS:8/integer, Bin/binary>>) ->
    %% @TODO something smarter
    {ok, binary_to_term(Bin)}.

is_operation(A) -> antidote_crdt_flag:is_operation(A).

is_bottom(Flag) ->
  Flag == new().

require_state_downstream(A) -> antidote_crdt_flag:require_state_downstream(A).

%% ===================================================================
%% Compression functions
%% ===================================================================

-spec can_compress(downstream_op(), downstream_op()) -> boolean().
can_compress(_, _) -> true.

-spec compress(downstream_op(), downstream_op()) -> {downstream_op() | noop, downstream_op() | noop}.
compress({SeenTokens1, NewEnableTokens1, NewDisableTokens1}, {SeenTokens2, NewEnableTokens2, NewDisableTokens2}) ->
    SeenTokens = SeenTokens1 ++ SeenTokens2,
    FinalEnableTokens = (NewEnableTokens1 ++ NewEnableTokens2) -- SeenTokens,
    FinalDisableTokens = (NewDisableTokens1 ++ NewDisableTokens2) -- SeenTokens,
    {noop, {SeenTokens, FinalEnableTokens, FinalDisableTokens}}.

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

compression_test() ->
    Token1 = antidote_crdt_flag:unique(),
    Token2 = antidote_crdt_flag:unique(),
    ?assertEqual(can_compress({[Token1], [], []}, {[Token2], [], []}), true),
    ?assertEqual(compress({[Token1], [], []}, {[Token2], [], []}), {noop, {[Token1, Token2], [], []}}),
    ?assertEqual(compress({[Token1], [], []}, {[], [], [Token1]}), {noop, {[Token1], [], []}}),
    ?assertEqual(compress({[Token1], [], []}, {[], [Token2], []}), {noop, {[Token1], [Token2], []}}).

-endif.
