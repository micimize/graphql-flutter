import 'package:graphql/src/exceptions/_base_exceptions.dart';
import './graphql_error.dart';

class OperationException implements Exception {
  List<GraphQLError> graphqlErrors = [];

  // generalize to include cache error, etc
  ClientException clientException;

  OperationException({
    this.clientException,
    Iterable<GraphQLError> graphqlErrors = const [],
  }) : this.graphqlErrors = graphqlErrors.toList();

  void addError(GraphQLError error) => graphqlErrors.add(error);
}

/// `(graphqlErrors?, exception?) => exception?`
///
/// merges both optional graphqlErrors and an optional container
/// into a single optional container
/// NOTE: NULL returns expected
OperationException coalesceErrors({
  List<GraphQLError> graphqlErrors,
  ClientException clientException,
  OperationException exception,
}) {
  if (exception != null ||
      clientException != null ||
      graphqlErrors == null ||
      graphqlErrors.isEmpty) {
    return OperationException(
      clientException: clientException ?? exception.clientException,
      graphqlErrors: [
        if (graphqlErrors != null) ...graphqlErrors,
        if (exception?.graphqlErrors != null) ...exception.graphqlErrors
      ],
    );
  }
  return null;
}
