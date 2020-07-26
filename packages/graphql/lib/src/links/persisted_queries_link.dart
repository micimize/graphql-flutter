import 'dart:async';
import 'dart:convert';
import 'package:graphql/src/utilities/get_from_ast.dart';
import 'package:meta/meta.dart';

import 'package:crypto/crypto.dart';
import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:graphql/client.dart';

import 'package:gql_link/gql_link.dart';
import 'package:gql_http_link/gql_http_link.dart';

import 'package:graphql/src/exceptions/exceptions_next.dart' as ex;

const VERSION = 1;

typedef QueryHashGenerator = String Function(DocumentNode query);

typedef ShouldDisablePersistedQueries = bool Function(
  Request request,
  Response response, [
  HttpLinkServerException exception,
]);

extension on Operation {
  bool get isQuery => isOfType(OperationType.query, document, operationName);
}

class PersistedQueriesLink extends Link {
  bool disabledDueToErrors = false;

  /// Adds a [HttpLinkMethod.get()] to context entry for hashed queries
  final bool useGETForHashedQueries;

  /// callback for hashing queries.
  ///
  /// Defaults to [defaultSha256Hash]
  final QueryHashGenerator getQueryHash;

  /// Called when [response] has errors to determine if the [PersistedQueriesLink] should be disabled
  ///
  /// Defaults to [defaultDisableOnError]
  final ShouldDisablePersistedQueries disableOnError;

  PersistedQueriesLink({
    this.useGETForHashedQueries = true,
    this.getQueryHash = defaultSha256Hash,
    this.disableOnError = defaultDisableOnError,
  }) : super();

  @override
  Stream<Response> request(
    Request request, [
    NextLink forward,
  ]) {
    if (forward == null) {
      throw Exception(
        'PersistedQueryLink cannot be the last link in the chain.',
      );
    }

    final operation = request.operation;

    var hashError;
    if (!disabledDueToErrors) {
      try {
        final doc = request.operation.document;
        final hash = getQueryHash(doc);
        // TODO awkward to inject the hash with a thunk like this
        request = request.withContextEntry(
          RequestExtensionsThunk(
            (request) {
              assert(
                request.operation.document == doc,
                'Request document altered after PersistedQueriesLink: '
                '${printNode(request.operation.document)} != ${printNode(doc)}',
              );
              return {
                'persistedQuery': {
                  'sha256Hash': hash,
                  'version': VERSION,
                },
              };
            },
          ),
        );
      } catch (e) {
        hashError = e;
      }
    }

    StreamController<Response> controller;

    Future<void> onListen() async {
      if (hashError != null) {
        return controller.addError(hashError);
      }

      StreamSubscription subscription;
      bool retried = false;
      Request originalRequest = request;

      Function retry;
      retry = ({
        Response response,
        HttpLinkServerException networkError,
        Function callback,
      }) {
        if (!retried && (response?.errors != null || networkError != null)) {
          retried = true;

          // TODO triple check that the original wholesale disables the link
          // if the server doesn't support persisted queries, don't try anymore
          disabledDueToErrors = disableOnError(request, response, networkError);

          // if its not found, we can try it again, otherwise just report the error
          if (!includesNotSupportedError(response) || disabledDueToErrors) {
            // need to recall the link chain
            if (subscription != null) {
              subscription.cancel();
            }

            // actually send the query this time
            final retryRequest = originalRequest.withContextEntry(
              RequestSerializationInclusions(
                query: true,
                extensions: !disabledDueToErrors,
              ),
            );

            subscription = _attachListener(
              controller,
              forward(retryRequest),
              retry,
            );

            return;
          }
        }

        callback();
      };

      // don't send the query the first time
      request = request.withContextEntry(
        RequestSerializationInclusions(
          query: disabledDueToErrors,
          extensions: !disabledDueToErrors,
        ),
      );

      // If requested, set method to GET if there are no mutations. Remember the
      if (useGETForHashedQueries && !disabledDueToErrors && operation.isQuery) {
        request = request.withContextEntry(HttpLinkMethod.get());
      }

      subscription = _attachListener(controller, forward(request), retry);
    }

    controller = StreamController<Response>(onListen: onListen);

    return controller.stream;
  }

  /// Default [getQueryHash] that `sha256` encodes the query document string
  static String defaultSha256Hash(DocumentNode query) =>
      sha256.convert(utf8.encode(printNode(query))).toString();

  /// Default [disableOnError].
  ///
  /// Disables the link if [includesNotSupportedError(response)] or if `statusCode` is in `{ 400, 500 }`
  static bool defaultDisableOnError(
    Request request,
    Response response, [
    HttpLinkServerException exception,
  ]) {
    // if the server doesn't support persisted queries, don't try anymore
    if (includesNotSupportedError(response)) {
      return true;
    }

    // if the server responds with bad request
    // apollo-server responds with 400 for GET and 500 for POST when no query is found

    final HttpLinkResponseContext responseContext = response.context.entry();

    return {400, 500}.contains(responseContext.statusCode);
  }

  static bool includesNotSupportedError(Response response) {
    final errors = response?.errors ?? [];
    return errors.any(
      (err) => err.message == 'PersistedQueryNotSupported',
    );
  }

  StreamSubscription _attachListener(
    StreamController<Response> controller,
    Stream<Response> stream,
    Function retry,
  ) {
    return stream.listen(
      (data) {
        retry(response: data, callback: () => controller.add(data));
      },
      onError: (err) {
        if (err is HttpLinkServerException) {
          retry(networkError: err, callback: () => controller.addError(err));
        } else {
          controller.addError(err);
        }
      },
      onDone: () {
        controller.close();
      },
      cancelOnError: true,
    );
  }
}
