//
//  Publishers+MergeMany.swift
//  Irisin
//
//  iOS 12 port: OpenCombine has no Publishers.MergeMany; the same merge of
//  every publisher's values, as a flat map over the list.
//

import OpenCombine

func mergeMany<Upstream: Publisher>(_ publishers: [Upstream]) -> AnyPublisher<Upstream.Output, Upstream.Failure> {
    Publishers.Sequence<[Upstream], Upstream.Failure>(sequence: publishers)
        .flatMap { $0 }
        .eraseToAnyPublisher()
}
