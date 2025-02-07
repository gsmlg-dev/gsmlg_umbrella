import MarkdownPreview from '@uiw/react-markdown-preview';

export const Component = ({ data }) => {
  return (
    <MarkdownPreview 
      source={data} 
      style={{ 
        color: 'var(--color-base-content)',
        backgroundColor: 'var(--color-base-200)',
        whiteSpace: 'pre-wrap',
        padding: '1rem',
      }}
    />
  );
}
