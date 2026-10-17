// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'hubbub.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$AppNodeEvent {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AppNodeEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AppNodeEvent()';
}


}

/// @nodoc
class $AppNodeEventCopyWith<$Res>  {
$AppNodeEventCopyWith(AppNodeEvent _, $Res Function(AppNodeEvent) __);
}


/// Adds pattern-matching-related methods to [AppNodeEvent].
extension AppNodeEventPatterns on AppNodeEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( AppNodeEvent_HostChanged value)?  hostChanged,TResult Function( AppNodeEvent_PeerUp value)?  peerUp,TResult Function( AppNodeEvent_PeerDown value)?  peerDown,TResult Function( AppNodeEvent_Text value)?  text,required TResult orElse(),}){
final _that = this;
switch (_that) {
case AppNodeEvent_HostChanged() when hostChanged != null:
return hostChanged(_that);case AppNodeEvent_PeerUp() when peerUp != null:
return peerUp(_that);case AppNodeEvent_PeerDown() when peerDown != null:
return peerDown(_that);case AppNodeEvent_Text() when text != null:
return text(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( AppNodeEvent_HostChanged value)  hostChanged,required TResult Function( AppNodeEvent_PeerUp value)  peerUp,required TResult Function( AppNodeEvent_PeerDown value)  peerDown,required TResult Function( AppNodeEvent_Text value)  text,}){
final _that = this;
switch (_that) {
case AppNodeEvent_HostChanged():
return hostChanged(_that);case AppNodeEvent_PeerUp():
return peerUp(_that);case AppNodeEvent_PeerDown():
return peerDown(_that);case AppNodeEvent_Text():
return text(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( AppNodeEvent_HostChanged value)?  hostChanged,TResult? Function( AppNodeEvent_PeerUp value)?  peerUp,TResult? Function( AppNodeEvent_PeerDown value)?  peerDown,TResult? Function( AppNodeEvent_Text value)?  text,}){
final _that = this;
switch (_that) {
case AppNodeEvent_HostChanged() when hostChanged != null:
return hostChanged(_that);case AppNodeEvent_PeerUp() when peerUp != null:
return peerUp(_that);case AppNodeEvent_PeerDown() when peerDown != null:
return peerDown(_that);case AppNodeEvent_Text() when text != null:
return text(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String? host,  BigInt term,  bool isMe)?  hostChanged,TResult Function( String member,  bool direct)?  peerUp,TResult Function( String member)?  peerDown,TResult Function( AppTextMessage message)?  text,required TResult orElse(),}) {final _that = this;
switch (_that) {
case AppNodeEvent_HostChanged() when hostChanged != null:
return hostChanged(_that.host,_that.term,_that.isMe);case AppNodeEvent_PeerUp() when peerUp != null:
return peerUp(_that.member,_that.direct);case AppNodeEvent_PeerDown() when peerDown != null:
return peerDown(_that.member);case AppNodeEvent_Text() when text != null:
return text(_that.message);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String? host,  BigInt term,  bool isMe)  hostChanged,required TResult Function( String member,  bool direct)  peerUp,required TResult Function( String member)  peerDown,required TResult Function( AppTextMessage message)  text,}) {final _that = this;
switch (_that) {
case AppNodeEvent_HostChanged():
return hostChanged(_that.host,_that.term,_that.isMe);case AppNodeEvent_PeerUp():
return peerUp(_that.member,_that.direct);case AppNodeEvent_PeerDown():
return peerDown(_that.member);case AppNodeEvent_Text():
return text(_that.message);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String? host,  BigInt term,  bool isMe)?  hostChanged,TResult? Function( String member,  bool direct)?  peerUp,TResult? Function( String member)?  peerDown,TResult? Function( AppTextMessage message)?  text,}) {final _that = this;
switch (_that) {
case AppNodeEvent_HostChanged() when hostChanged != null:
return hostChanged(_that.host,_that.term,_that.isMe);case AppNodeEvent_PeerUp() when peerUp != null:
return peerUp(_that.member,_that.direct);case AppNodeEvent_PeerDown() when peerDown != null:
return peerDown(_that.member);case AppNodeEvent_Text() when text != null:
return text(_that.message);case _:
  return null;

}
}

}

/// @nodoc


class AppNodeEvent_HostChanged extends AppNodeEvent {
  const AppNodeEvent_HostChanged({this.host, required this.term, required this.isMe}): super._();
  

 final  String? host;
 final  BigInt term;
 final  bool isMe;

/// Create a copy of AppNodeEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppNodeEvent_HostChangedCopyWith<AppNodeEvent_HostChanged> get copyWith => _$AppNodeEvent_HostChangedCopyWithImpl<AppNodeEvent_HostChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AppNodeEvent_HostChanged&&(identical(other.host, host) || other.host == host)&&(identical(other.term, term) || other.term == term)&&(identical(other.isMe, isMe) || other.isMe == isMe));
}


@override
int get hashCode {
    return Object.hash(runtimeType,host,term,isMe);
}

@override
String toString() {
    return 'AppNodeEvent.hostChanged(host: $host, term: $term, isMe: $isMe)';
}


}

/// @nodoc
abstract mixin class $AppNodeEvent_HostChangedCopyWith<$Res> implements $AppNodeEventCopyWith<$Res> {
  factory $AppNodeEvent_HostChangedCopyWith(AppNodeEvent_HostChanged value, $Res Function(AppNodeEvent_HostChanged) _then) = _$AppNodeEvent_HostChangedCopyWithImpl;
@useResult
$Res call({
 String? host, BigInt term, bool isMe
});




}
/// @nodoc
class _$AppNodeEvent_HostChangedCopyWithImpl<$Res>
    implements $AppNodeEvent_HostChangedCopyWith<$Res> {
  _$AppNodeEvent_HostChangedCopyWithImpl(this._self, this._then);

  final AppNodeEvent_HostChanged _self;
  final $Res Function(AppNodeEvent_HostChanged) _then;

/// Create a copy of AppNodeEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? host = freezed,Object? term = null,Object? isMe = null,}) {
  return _then(AppNodeEvent_HostChanged(
host: freezed == host ? _self.host : host // ignore: cast_nullable_to_non_nullable
as String?,term: null == term ? _self.term : term // ignore: cast_nullable_to_non_nullable
as BigInt,isMe: null == isMe ? _self.isMe : isMe // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class AppNodeEvent_PeerUp extends AppNodeEvent {
  const AppNodeEvent_PeerUp({required this.member, required this.direct}): super._();
  

 final  String member;
 final  bool direct;

/// Create a copy of AppNodeEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppNodeEvent_PeerUpCopyWith<AppNodeEvent_PeerUp> get copyWith => _$AppNodeEvent_PeerUpCopyWithImpl<AppNodeEvent_PeerUp>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AppNodeEvent_PeerUp&&(identical(other.member, member) || other.member == member)&&(identical(other.direct, direct) || other.direct == direct));
}


@override
int get hashCode {
    return Object.hash(runtimeType,member,direct);
}

@override
String toString() {
    return 'AppNodeEvent.peerUp(member: $member, direct: $direct)';
}


}

/// @nodoc
abstract mixin class $AppNodeEvent_PeerUpCopyWith<$Res> implements $AppNodeEventCopyWith<$Res> {
  factory $AppNodeEvent_PeerUpCopyWith(AppNodeEvent_PeerUp value, $Res Function(AppNodeEvent_PeerUp) _then) = _$AppNodeEvent_PeerUpCopyWithImpl;
@useResult
$Res call({
 String member, bool direct
});




}
/// @nodoc
class _$AppNodeEvent_PeerUpCopyWithImpl<$Res>
    implements $AppNodeEvent_PeerUpCopyWith<$Res> {
  _$AppNodeEvent_PeerUpCopyWithImpl(this._self, this._then);

  final AppNodeEvent_PeerUp _self;
  final $Res Function(AppNodeEvent_PeerUp) _then;

/// Create a copy of AppNodeEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? member = null,Object? direct = null,}) {
  return _then(AppNodeEvent_PeerUp(
member: null == member ? _self.member : member // ignore: cast_nullable_to_non_nullable
as String,direct: null == direct ? _self.direct : direct // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class AppNodeEvent_PeerDown extends AppNodeEvent {
  const AppNodeEvent_PeerDown({required this.member}): super._();
  

 final  String member;

/// Create a copy of AppNodeEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppNodeEvent_PeerDownCopyWith<AppNodeEvent_PeerDown> get copyWith => _$AppNodeEvent_PeerDownCopyWithImpl<AppNodeEvent_PeerDown>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AppNodeEvent_PeerDown&&(identical(other.member, member) || other.member == member));
}


@override
int get hashCode {
    return Object.hash(runtimeType,member);
}

@override
String toString() {
    return 'AppNodeEvent.peerDown(member: $member)';
}


}

/// @nodoc
abstract mixin class $AppNodeEvent_PeerDownCopyWith<$Res> implements $AppNodeEventCopyWith<$Res> {
  factory $AppNodeEvent_PeerDownCopyWith(AppNodeEvent_PeerDown value, $Res Function(AppNodeEvent_PeerDown) _then) = _$AppNodeEvent_PeerDownCopyWithImpl;
@useResult
$Res call({
 String member
});




}
/// @nodoc
class _$AppNodeEvent_PeerDownCopyWithImpl<$Res>
    implements $AppNodeEvent_PeerDownCopyWith<$Res> {
  _$AppNodeEvent_PeerDownCopyWithImpl(this._self, this._then);

  final AppNodeEvent_PeerDown _self;
  final $Res Function(AppNodeEvent_PeerDown) _then;

/// Create a copy of AppNodeEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? member = null,}) {
  return _then(AppNodeEvent_PeerDown(
member: null == member ? _self.member : member // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AppNodeEvent_Text extends AppNodeEvent {
  const AppNodeEvent_Text({required this.message}): super._();
  

 final  AppTextMessage message;

/// Create a copy of AppNodeEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppNodeEvent_TextCopyWith<AppNodeEvent_Text> get copyWith => _$AppNodeEvent_TextCopyWithImpl<AppNodeEvent_Text>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AppNodeEvent_Text&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode {
    return Object.hash(runtimeType,message);
}

@override
String toString() {
    return 'AppNodeEvent.text(message: $message)';
}


}

/// @nodoc
abstract mixin class $AppNodeEvent_TextCopyWith<$Res> implements $AppNodeEventCopyWith<$Res> {
  factory $AppNodeEvent_TextCopyWith(AppNodeEvent_Text value, $Res Function(AppNodeEvent_Text) _then) = _$AppNodeEvent_TextCopyWithImpl;
@useResult
$Res call({
 AppTextMessage message
});




}
/// @nodoc
class _$AppNodeEvent_TextCopyWithImpl<$Res>
    implements $AppNodeEvent_TextCopyWith<$Res> {
  _$AppNodeEvent_TextCopyWithImpl(this._self, this._then);

  final AppNodeEvent_Text _self;
  final $Res Function(AppNodeEvent_Text) _then;

/// Create a copy of AppNodeEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(AppNodeEvent_Text(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as AppTextMessage,
  ));
}


}

// dart format on
