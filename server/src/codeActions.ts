// This file holds code actions derived from diagnostics. There are more code
// actions available in the extension, but they are derived via the analysis
// OCaml binary.
import * as p from "vscode-languageserver-protocol";

export type filesCodeActions = {
  [key: string]: { range: p.Range; codeAction: p.CodeAction }[];
};

interface findCodeActionsConfig {
  diagnostic: p.Diagnostic;
  diagnosticMessage: string[];
  file: string;
  range: p.Range;
  addFoundActionsHere: filesCodeActions;
}

let wrapRangeInText = (
  range: p.Range,
  wrapStart: string,
  wrapEnd: string
): p.TextEdit[] => {
  // We need to adjust the start of where we replace if this is a single
  // character on a single line.
  let offset =
    range.start.line === range.end.line &&
    range.start.character === range.end.character
      ? 1
      : 0;

  let startRange = {
    start: {
      line: range.start.line,
      character: range.start.character - offset,
    },
    end: {
      line: range.start.line,
      character: range.start.character - offset,
    },
  };

  let endRange = {
    start: {
      line: range.end.line,
      character: range.end.character,
    },
    end: {
      line: range.end.line,
      character: range.end.character,
    },
  };

  return [
    {
      range: startRange,
      newText: wrapStart,
    },
    {
      range: endRange,
      newText: wrapEnd,
    },
  ];
};

let insertBeforeEndingChar = (
  range: p.Range,
  newText: string
): p.TextEdit[] => {
  let beforeEndingChar = {
    line: range.end.line,
    character: range.end.character - 1,
  };

  return [
    {
      range: {
        start: beforeEndingChar,
        end: beforeEndingChar,
      },
      newText,
    },
  ];
};

export let findCodeActionsInDiagnosticsMessage = ({
  diagnostic,
  diagnosticMessage,
  file,
  range,
  addFoundActionsHere: codeActions,
}: findCodeActionsConfig) => {
  diagnosticMessage.forEach((line, index, array) => {
    // Because of how actions work, there can only be one per diagnostic. So,
    // halt whenever a code action has been found.
    let actions = [
      didYouMeanAction,
      addUndefinedRecordFields,
      simpleConversion,
      topLevelUnitType,
      applyUncurried,
      simpleAddMissingCases,
      simpleWrapOptionalWithSome,
    ];

    for (let action of actions) {
      if (
        action({
          array,
          codeActions,
          diagnostic,
          file,
          index,
          line,
          range,
        })
      ) {
        break;
      }
    }
  });
};

interface codeActionExtractorConfig {
  line: string;
  index: number;
  array: string[];
  file: string;
  range: p.Range;
  diagnostic: p.Diagnostic;
  codeActions: filesCodeActions;
}

type codeActionExtractor = (config: codeActionExtractorConfig) => boolean;

let didYouMeanAction: codeActionExtractor = ({
  codeActions,
  diagnostic,
  file,
  line,
  range,
}) => {
  if (line.startsWith("Hint: Did you mean")) {
    let regex = /Did you mean ([A-Za-z0-9_]*)?/;
    let match = line.match(regex);

    if (match === null) {
      return false;
    }

    let [_, suggestion] = match;

    if (suggestion != null) {
      codeActions[file] = codeActions[file] || [];
      let codeAction: p.CodeAction = {
        title: `Replace with '${suggestion}'`,
        edit: {
          changes: {
            [file]: [{ range, newText: suggestion }],
          },
        },
        diagnostics: [diagnostic],
        kind: p.CodeActionKind.QuickFix,
        isPreferred: true,
      };

      codeActions[file].push({
        range,
        codeAction,
      });

      return true;
    }
  }

  return false;
};

let addUndefinedRecordFields: codeActionExtractor = ({
  array,
  codeActions,
  diagnostic,
  file,
  index,
  line,
  range,
}) => {
  if (line.startsWith("Some record fields are undefined:")) {
    let recordFieldNames = line
      .trim()
      .split("Some record fields are undefined: ")[1]
      ?.split(" ");

    // This collects the rest of the fields if fields are printed on
    // multiple lines.
    array.slice(index + 1).forEach((line) => {
      recordFieldNames.push(...line.trim().split(" "));
    });

    if (recordFieldNames != null) {
      codeActions[file] = codeActions[file] || [];

      // The formatter outputs trailing commas automatically if the record
      // definition is on multiple lines, and no trailing comma if it's on a
      // single line. We need to adapt to this so we don't accidentally
      // insert an invalid comma.
      let multilineRecordDefinitionBody = range.start.line !== range.end.line;

      // Let's build up the text we're going to insert.
      let newText = "";

      if (multilineRecordDefinitionBody) {
        // If it's a multiline body, we know it looks like this:
        // ```
        // let someRecord = {
        //   atLeastOneExistingField: string,
        // }
        // ```
        // We can figure out the formatting from the range the code action
        // gives us. We'll insert to the direct left of the ending brace.

        // The end char is the closing brace, and it's always going to be 2
        // characters back from the record fields.
        let paddingCharacters = multilineRecordDefinitionBody
          ? range.end.character + 2
          : 0;
        let paddingContentRecordField = Array.from({
          length: paddingCharacters,
        }).join(" ");
        let paddingContentEndBrace = Array.from({
          length: range.end.character,
        }).join(" ");

        recordFieldNames.forEach((fieldName, index) => {
          if (index === 0) {
            // This adds spacing from the ending brace up to the equivalent
            // of the last record field name, needed for the first inserted
            // record field name.
            newText += "  ";
          } else {
            // The rest of the new record field names will start from a new
            // line, so they need left padding all the way to the same level
            // as the rest of the record fields.
            newText += paddingContentRecordField;
          }

          newText += `${fieldName}: assert false,\n`;
        });

        // Let's put the end brace back where it was (we still have it to the direct right of us).
        newText += `${paddingContentEndBrace}`;
      } else {
        // A single line record definition body is a bit easier - we'll just add the new fields on the same line.
        newText += ", ";
        newText += recordFieldNames
          .map((fieldName) => `${fieldName}: assert false`)
          .join(", ");
      }

      let codeAction: p.CodeAction = {
        title: `Add missing record fields`,
        edit: {
          changes: {
            [file]: insertBeforeEndingChar(range, newText),
          },
        },
        diagnostics: [diagnostic],
        kind: p.CodeActionKind.QuickFix,
        isPreferred: true,
      };

      codeActions[file].push({
        range,
        codeAction,
      });

      return true;
    }
  }

  return false;
};

let simpleConversion: codeActionExtractor = ({
  line,
  codeActions,
  file,
  range,
  diagnostic,
}) => {
  if (line.startsWith("You can convert ")) {
    let regex = /You can convert (\w*) to (\w*) with ([\w.]*).$/;
    let match = line.match(regex);

    if (match === null) {
      return false;
    }

    let [_, from, to, fn] = match;

    if (from != null && to != null && fn != null) {
      codeActions[file] = codeActions[file] || [];

      let codeAction: p.CodeAction = {
        title: `Convert ${from} to ${to} with ${fn}`,
        edit: {
          changes: {
            [file]: wrapRangeInText(range, `${fn}(`, `)`),
          },
        },
        diagnostics: [diagnostic],
        kind: p.CodeActionKind.QuickFix,
        isPreferred: true,
      };

      codeActions[file].push({
        range,
        codeAction,
      });

      return true;
    }
  }

  return false;
};

let applyUncurried: codeActionExtractor = ({
  line,
  codeActions,
  file,
  range,
  diagnostic,
}) => {
  if (
    line.startsWith(
      "This is an uncurried ReScript function. It must be applied with a dot."
    )
  ) {
    const locOfOpenFnParens = {
      line: range.end.line,
      character: range.end.character + 1,
    };

    codeActions[file] = codeActions[file] || [];
    let codeAction: p.CodeAction = {
      title: `Apply uncurried function call with dot`,
      edit: {
        changes: {
          [file]: [
            {
              range: {
                start: locOfOpenFnParens,
                end: locOfOpenFnParens,
              },
              /*
               * Turns `fn(123)` into `fn(. 123)`.
               */
              newText: `. `,
            },
          ],
        },
      },
      diagnostics: [diagnostic],
      kind: p.CodeActionKind.QuickFix,
      isPreferred: true,
    };

    codeActions[file].push({
      range,
      codeAction,
    });

    return true;
  }

  return false;
};

let topLevelUnitType: codeActionExtractor = ({
  line,
  codeActions,
  file,
  range,
  diagnostic,
}) => {
  if (line.startsWith("Toplevel expression is expected to have unit type.")) {
    codeActions[file] = codeActions[file] || [];
    let codeAction: p.CodeAction = {
      title: `Wrap expression in ignore`,
      edit: {
        changes: {
          [file]: wrapRangeInText(range, "ignore(", ")"),
        },
      },
      diagnostics: [diagnostic],
      kind: p.CodeActionKind.QuickFix,
      isPreferred: true,
    };

    codeActions[file].push({
      range,
      codeAction,
    });

    return true;
  }

  return false;
};

// This protects against the fact that the compiler currently returns most
// text in OCaml. It also ensures that we only return simple constructors.
let isValidVariantCase = (text: string): boolean => {
  if (text.startsWith("(") || text.includes(",")) {
    return false;
  }

  return true;
};

// Untransformed is typically OCaml, and looks like these examples:
//
// `SomeVariantName
//
// SomeVariantWithPayload _
//
// ...and we'll need to transform this into proper ReScript. In the future, the
// compiler itself should of course output real ReScript. But it currently does
// not.
let transformVariant = (variant: string): string | null => {
  // Convert old polyvariant notation to new
  let text = variant.replace(/`/g, "#");

  // Fix payloads
  if (text.includes(" ")) {
    let [variantText, payloadText] = text.split(" ");

    // If the payload itself starts with (, it's another variant with a
    // constructor. We bail in that case, for now at least. We'll be able to
    // revisit this in the future when the compiler prints real ReScript syntax.
    if (payloadText.startsWith("(")) {
      return null;
    }

    text = `${variantText}(${payloadText})`;
  }

  return text;
};

let simpleAddMissingCases: codeActionExtractor = ({
  line,
  codeActions,
  file,
  range,
  diagnostic,
  array,
  index,
}) => {
  // Examples:
  //
  // You forgot to handle a possible case here, for example:
  // (AnotherValue|Third|Fourth)
  //
  // You forgot to handle a possible case here, for example:
  // (`AnotherValue|`Third|`Fourth)
  //
  // You forgot to handle a possible case here, for example:
  // `AnotherValue
  //
  // You forgot to handle a possible case here, for example:
  // AnotherValue

  if (
    line.startsWith("You forgot to handle a possible case here, for example:")
  ) {
    let cases: string[] = [];

    // This collects the rest of the fields if fields are printed on
    // multiple lines.
    array.slice(index + 1).forEach((line) => {
      let theLine = line.trim();

      let hasMultipleCases = theLine.includes("|");

      if (hasMultipleCases) {
        cases.push(
          ...(theLine
            // Remove leading and ending parens
            .slice(1, theLine.length - 1)
            .split("|")
            .filter(isValidVariantCase)
            .map(transformVariant)
            .filter(Boolean) as string[])
        );
      } else {
        let transformed = transformVariant(theLine);
        if (isValidVariantCase(theLine) && transformed != null) {
          cases.push(transformed);
        }
      }
    });

    if (cases.length === 0) {
      return false;
    }

    // The end char is the closing brace. In switches, the leading `|` always
    // has the same left padding as the end brace.
    let paddingContentSwitchCase = Array.from({
      length: range.end.character,
    }).join(" ");

    let newText = cases
      .map((variantName, index) => {
        // The first case will automatically be padded because we're inserting
        // it where the end brace is currently located.
        let padding = index === 0 ? "" : paddingContentSwitchCase;
        return `${padding}| ${variantName} => assert false`;
      })
      .join("\n");

    // Let's put the end brace back where it was (we still have it to the direct right of us).
    newText += `\n${paddingContentSwitchCase}`;

    codeActions[file] = codeActions[file] || [];
    let codeAction: p.CodeAction = {
      title: `Insert missing cases`,
      edit: {
        changes: {
          [file]: insertBeforeEndingChar(range, newText),
        },
      },
      diagnostics: [diagnostic],
      kind: p.CodeActionKind.QuickFix,
      isPreferred: true,
    };

    codeActions[file].push({
      range,
      codeAction,
    });

    return true;
  }

  return false;
};

let simpleWrapOptionalWithSome: codeActionExtractor = ({
  line,
  codeActions,
  file,
  range,
  diagnostic,
  array,
  index,
}) => {
  // Examples:
  //
  // 46 │ let as_ = {
  // 47 │   someProp: "123",
  // 48 │   another: "123",
  // 49 │ }
  // 50 │
  // This has type: string
  // Somewhere wanted: option<string>

  if (line.startsWith("Somewhere wanted: option<")) {
    let somewhereWantedLine = line;
    let thisHasTypeLine = array[index - 1];
    let hasTypeText = thisHasTypeLine.split("This has type: ")[1].trim();
    let somewhereWantedText = somewhereWantedLine
      .split("Somewhere wanted: option<")[1]
      .trim();

    // Remove ending `>` so we can compare the underlying types
    somewhereWantedText = somewhereWantedText.slice(
      0,
      somewhereWantedText.length - 1
    );

    // We only trigger the code action if the thing that's already there is the
    // exact same type.
    if (hasTypeText === somewhereWantedText) {
      codeActions[file] = codeActions[file] || [];
      let codeAction: p.CodeAction = {
        title: `Wrap value in Some`,
        edit: {
          changes: {
            [file]: wrapRangeInText(range, "Some(", ")"),
          },
        },
        diagnostics: [diagnostic],
        kind: p.CodeActionKind.QuickFix,
        isPreferred: true,
      };

      codeActions[file].push({
        range,
        codeAction,
      });

      return true;
    }
  }

  return false;
};
