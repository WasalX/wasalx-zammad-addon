// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
export const getAcceptableFileTypesString = (files: Array<{ types: string[] }>) =>
  files.flatMap((file) => file.types).join(',')
