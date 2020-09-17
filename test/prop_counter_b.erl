%% -------------------------------------------------------------------
%%
%% Copyright <2013-2018> <
%%  Technische Universität Kaiserslautern, Germany
%%  Université Pierre et Marie Curie / Sorbonne-Université, France
%%  Universidade NOVA de Lisboa, Portugal
%%  Université catholique de Louvain (UCL), Belgique
%%  INESC TEC, Portugal
%% >
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
%% KIND, either expressed or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% List of the contributors to the development of Antidote: see AUTHORS file.
%% Description and complete License: see LICENSE file.
%% -------------------------------------------------------------------

-module(prop_counter_b).

-define(PROPER_NO_TRANS, true).
-include_lib("proper/include/proper.hrl").

%% API
-export([prop_is_operation_test/0, prop_is_not_operation_test/0, prop_increment_decrement_test/0]).


%%%%%%%%%%%%%%%%%%
%%% Properties %%%
%%%%%%%%%%%%%%%%%%

prop_is_operation_test() ->
    ?FORALL(Operation, valid_operations(),
        begin
            antidote_crdt_counter_b:is_operation(Operation)
        end).

prop_is_not_operation_test() ->
    ?FORALL(Operation, invalid_negative_operations(),
        begin
            not antidote_crdt_counter_b:is_operation(Operation)
        end).

prop_increment_decrement_test() ->
    proper:forall(get_increment_decrement_ops(),
        fun(OpType) ->
            {IncrementOp = {increment, {IncrementValue, undefined}}, DecrementOp = {decrement, {DecrementValue, undefined}}} = OpType,
            Counter1 = antidote_crdt_counter_b:new(),
            true = antidote_crdt_counter_b:is_operation(IncrementOp),
            true = antidote_crdt_counter_b:is_operation(DecrementOp),
            {error, no_permissions} = antidote_crdt_counter_b:downstream(DecrementOp, Counter1),
            {ok, IncrementEffect} = antidote_crdt_counter_b:downstream(IncrementOp, Counter1),
            {ok, Counter2} = antidote_crdt_counter_b:update(IncrementEffect, Counter1),
            DecrementEffectResult = antidote_crdt_counter_b:downstream(DecrementOp, Counter2),
            case IncrementValue >= DecrementValue of
                true ->
                    {ok, DecrementEffect} = DecrementEffectResult,
                    {ok, Counter3} = antidote_crdt_counter_b:update(DecrementEffect, Counter2),
                    CorrectPermissions = IncrementValue - DecrementValue,
                    TotalPermissions = antidote_crdt_counter_b:permissions(Counter3),
                    LocalPermissions = antidote_crdt_counter_b:local_permissions(undefined, Counter3),
                    true = CorrectPermissions == TotalPermissions,
                    true = TotalPermissions == LocalPermissions;
                false ->
                    {error, no_permissions} == DecrementEffectResult
            end
        end).

%%%%%%%%%%%%%%%
%%% Helpers %%%
%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%
%%% Generators %%%
%%%%%%%%%%%%%%%%%%

valid_operations() ->
    oneof(
        [
            {oneof([increment, decrement]), oneof([pos_integer(), {pos_integer(), term()}])},
            {transfer, oneof([{pos_integer(), term()}, {pos_integer(), term(), term()}])}
        ]).

invalid_negative_operations() ->
    oneof(
        [
            {oneof([increment, decrement]), oneof([oneof([neg_integer(), 0]), {oneof([neg_integer(), 0]), term()}])},
            {transfer, oneof([{oneof([neg_integer(), 0]), term()}, {oneof([neg_integer(), 0]), term(), term()}])}
        ]).

get_increment_decrement_ops() ->
    {{increment, {pos_integer(), undefined}}, {decrement, {pos_integer(), undefined}}}.
