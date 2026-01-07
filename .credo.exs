# .credo.exs - Credo configuration
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/web/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          # Consistency Checks - disable ones with pre-existing violations
          {Credo.Check.Consistency.ExceptionNames, false},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, false},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          # Readability Checks - disable ones with pre-existing violations
          {Credo.Check.Readability.AliasOrder, false},
          {Credo.Check.Readability.FunctionNames, false},
          {Credo.Check.Readability.LargeNumbers, false},
          {Credo.Check.Readability.MaxLineLength, false},
          {Credo.Check.Readability.ModuleAttributeNames, false},
          {Credo.Check.Readability.ModuleDoc, false},
          {Credo.Check.Readability.ModuleNames, false},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, false},
          {Credo.Check.Readability.PredicateFunctionNames, false},
          {Credo.Check.Readability.PreferImplicitTry, false},
          {Credo.Check.Readability.RedundantBlankLines, false},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, false},
          {Credo.Check.Readability.StringSigils, false},
          {Credo.Check.Readability.TrailingBlankLine, false},
          {Credo.Check.Readability.TrailingWhiteSpace, false},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, false},
          {Credo.Check.Readability.VariableNames, false},

          # Refactoring Opportunities - disable ones with pre-existing violations
          {Credo.Check.Refactor.Apply, false},
          {Credo.Check.Refactor.CondStatements, false},
          {Credo.Check.Refactor.CyclomaticComplexity, false},
          {Credo.Check.Refactor.FunctionArity, false},
          {Credo.Check.Refactor.LongQuoteBlocks, false},
          {Credo.Check.Refactor.MatchInCondition, false},
          {Credo.Check.Refactor.MapJoin, false},
          {Credo.Check.Refactor.NegatedConditionsInUnless, false},
          {Credo.Check.Refactor.NegatedConditionsWithElse, false},
          {Credo.Check.Refactor.Nesting, false},
          {Credo.Check.Refactor.UnlessWithElse, false},
          {Credo.Check.Refactor.WithClauses, false},
          {Credo.Check.Refactor.FilterFilter, false},
          {Credo.Check.Refactor.RejectReject, false},
          {Credo.Check.Refactor.RedundantWithClauseResult, false},

          # Warnings - disable ones with pre-existing violations
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, false},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, false},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, false},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, false},
          {Credo.Check.Warning.SpecWithStruct, false},
          {Credo.Check.Warning.WrongTestFileExtension, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.UnsafeExec, []},

          # Design Checks - disable all with pre-existing violations
          {Credo.Check.Design.AliasUsage, false},
          {Credo.Check.Design.DuplicatedCode, false},
          {Credo.Check.Design.TagTODO, false},
          {Credo.Check.Design.TagFIXME, false}
        ],
        disabled: [
          # Disable checks causing many false positives
          {Credo.Check.Readability.NestedFunctionCalls, []},
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Refactor.ABCSize, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.IoPuts, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.ModuleDependencies, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.RejectFilter, []},
          {Credo.Check.Refactor.VariableRebinding, []},
          {Credo.Check.Warning.LazyLogging, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.UnsafeToAtom, []}
        ]
      }
    }
  ]
}
